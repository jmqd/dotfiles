//! agent-box: run coding agents on an untrusted GitHub repo inside a colima
//! VM, with GitHub write access limited to that repo, branch, or PR.

mod github;
mod policy;
mod proxy;
#[cfg(test)]
mod proxy_tests;
mod receive_pack;
mod setup;
mod target;
mod tls;
mod vm;

use anyhow::{Context as _, ensure};
use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use target::{Scope, Target};
use tokio::net::TcpListener;

const DEFAULT_KEY_FILE: &str = "~/src/home/secrets/agent-box-github-app.yaml";
const DEFAULT_WORKROOT: &str = "~/agent-work";

/// Tools every session gets, from the dotfiles flake's locked nixpkgs.
const BASE_PACKAGES: &[&str] = &[
    "bashInteractive",
    "cacert",
    "coreutils",
    "curl",
    "diffutils",
    "fd",
    "findutils",
    "gawk",
    "gh",
    "git",
    "gnugrep",
    "gnused",
    "gnutar",
    "gzip",
    "jq",
    "less",
    "procps",
    "ripgrep",
    "which",
];
/// Agents packaged by the dotfiles flake.
const AGENTS: &[&str] = &["omp", "claude-code", "antigravity-cli"];

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// sops-encrypted GitHub App credentials.
    #[arg(long, global = true, env = "AGENT_BOX_KEY_FILE", default_value = DEFAULT_KEY_FILE)]
    key_file: String,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Create the GitHub App that mints session tokens (once).
    Setup {
        /// Create the app under this organization instead of your account.
        #[arg(long)]
        org: Option<String>,
    },
    /// Open a shell in a sandbox for a repo, branch, or pull request.
    Run(RunArgs),
}

#[derive(clap::Args)]
struct RunArgs {
    /// github.com URL of a repo, a branch (/tree/NAME), or a PR (/pull/N).
    target: String,
    /// Extra Nix package for the session: a nixpkgs attribute (`lean4`) or any
    /// flake installable (`github:owner/repo#pkg`). Repeatable.
    #[arg(long = "pkg", value_name = "PACKAGE")]
    packages: Vec<String>,
    /// Host environment variable to copy into the session, such as an agent's
    /// API key. Repeatable.
    #[arg(long = "env", value_name = "NAME")]
    pass_env: Vec<String>,
    /// Directory the VM shares with the host; workspaces live under it.
    #[arg(long, env = "AGENT_BOX_WORKROOT", default_value = DEFAULT_WORKROOT)]
    workroot: String,
    #[arg(long, default_value_t = 4)]
    cpus: u32,
    #[arg(long, default_value_t = 8)]
    memory_gib: u32,
    /// Command to run in the repo instead of an interactive shell.
    #[arg(last = true)]
    command: Vec<String>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let runtime = match tokio::runtime::Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("agent-box: {error}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(dispatch(cli)) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("agent-box: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn dispatch(cli: Cli) -> anyhow::Result<ExitCode> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("a TLS crypto provider was already installed"))?;
    let key_file = expand_home(&cli.key_file)?;
    match cli.command {
        Commands::Setup { org } => {
            setup::setup(&key_file, org.as_deref()).await?;
            Ok(ExitCode::SUCCESS)
        }
        Commands::Run(args) => run(&key_file, args).await,
    }
}

async fn run(key_file: &Path, args: RunArgs) -> anyhow::Result<ExitCode> {
    let target: Target = args.target.parse()?;
    let flake_source = PathBuf::from(
        std::env::var_os("AGENT_BOX_FLAKE")
            .context("AGENT_BOX_FLAKE is unset; run agent-box through its Nix package")?,
    );
    for name in &args.pass_env {
        ensure!(
            std::env::var_os(name).is_some(),
            "--env {name}: not set on the host"
        );
    }
    let workroot = expand_home(&args.workroot)?;
    std::fs::create_dir_all(&workroot)?;
    let workroot = workroot.canonicalize()?;

    let app = github::App::load(key_file)?;
    let tokens = github::Tokens::new(app, github::https_client(), target.repo.clone()).await?;
    let grant = tokens.grant(&target).await?;

    vm::ensure_vm(
        &workroot,
        &vm::VmSize {
            cpus: args.cpus,
            memory_gib: args.memory_gib,
        },
    )?;
    let flake = vm::stage_flake(&workroot, &flake_source)?;
    let store_paths = vm::realize(&flake, &installables(&args.packages))?;

    let workspace_path = target.workspace_path();
    let workspace = workroot.join(&workspace_path);
    std::fs::create_dir_all(&workspace)?;
    // The container can write anything under `workspace`, including symlinks
    // virtiofs keeps on the host, so the host never writes there. Session
    // files live in a directory only the host writes and the container sees
    // read-only.
    let state = workroot.join(".agent-box");
    let control = state.join("sessions").join(&workspace_path);
    std::fs::create_dir_all(&control)?;
    let ca = tls::SessionCa::new(&["github.com", "api.github.com"])?;
    std::fs::write(control.join("ca.pem"), &ca.cert_pem)?;
    std::fs::write(control.join("init.sh"), include_str!("box-init.sh"))?;

    let mut log_path = state.join("logs").join(&workspace_path);
    log_path.as_mut_os_string().push(".log");
    std::fs::create_dir_all(log_path.parent().context("log path has no parent")?)?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)?;

    // Loopback only: colima forwards the VM's host.docker.internal here.
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let secret = random_hex(24)?;
    let description = grant.describe();
    let branch = match (&target.scope, &grant.access) {
        (Scope::Branch(branch), _) => Some(branch.clone()),
        (
            _,
            policy::Access::Pr {
                head: policy::PrHead::SameRepo(branch),
                ..
            },
        ) => Some(branch.clone()),
        _ => None,
    };
    let fork_pr = match &grant.access {
        policy::Access::Pr {
            number,
            head: policy::PrHead::Fork,
            ..
        } => Some(*number),
        _ => None,
    };
    let can_push = !matches!(
        grant.access,
        policy::Access::Pr {
            head: policy::PrHead::Fork,
            ..
        }
    );
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::clone(&ca.server_config));
    let proxy = Arc::new(proxy::Proxy::new(
        &secret,
        acceptor,
        grant,
        tokens,
        proxy::Upstream::github(),
        log,
    ));
    tokio::spawn(proxy.serve(listener));
    let firewall = vm::Firewall::install(port)?;

    let mut env = vec![
        ("HOME".to_owned(), "/work/home".to_owned()),
        ("AGENT_BOX_STORE_PATHS".to_owned(), store_paths.join(":")),
        (
            "AGENT_BOX_PROXY".to_owned(),
            format!(
                "http://{}:{secret}@host.docker.internal:{port}",
                proxy::PROXY_USER
            ),
        ),
        ("AGENT_BOX_REPO".to_owned(), target.repo.to_string()),
        ("AGENT_BOX_GRANT".to_owned(), description),
    ];
    if let Some(branch) = branch {
        env.push(("AGENT_BOX_BRANCH".to_owned(), branch));
    }
    if let Some(number) = fork_pr {
        env.push(("AGENT_BOX_PR".to_owned(), number.to_string()));
    }
    for (key, git_key) in [
        ("AGENT_BOX_GIT_NAME", "user.name"),
        ("AGENT_BOX_GIT_EMAIL", "user.email"),
    ] {
        if let Some(value) = git_config(git_key) {
            env.push((key.to_owned(), value));
        }
    }

    eprintln!("agent-box: proxy log: {}", log_path.display());
    if can_push {
        eprintln!(
            "agent-box: warning: pushes run {}'s CI workflows on the pushed code, with the secrets those workflows can read",
            target.repo
        );
    }
    let status = vm::run_session(vm::Session {
        name: format!("agent-box-{}", random_hex(4)?),
        workspace: &workspace,
        control: &control,
        env,
        pass_env: &args.pass_env,
        command: &args.command,
    })
    .await;
    firewall.remove();
    let status = status?;
    Ok(status
        .code()
        .and_then(|code| u8::try_from(code).ok())
        .map_or(ExitCode::FAILURE, ExitCode::from))
}

fn installables(extra: &[String]) -> Vec<String> {
    BASE_PACKAGES
        .iter()
        .map(|name| format!("nixpkgs#{name}"))
        .chain(AGENTS.iter().map(|name| format!("/flake#{name}")))
        .chain(extra.iter().map(|package| {
            if package.contains('#') {
                package.clone()
            } else {
                format!("nixpkgs#{package}")
            }
        }))
        .collect()
}

fn git_config(key: &str) -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["config", "--get", key])
        .output()
        .ok()?;
    let value = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (output.status.success() && !value.is_empty()).then_some(value)
}

fn expand_home(path: &str) -> anyhow::Result<PathBuf> {
    match path.strip_prefix("~/") {
        Some(rest) => {
            let home = std::env::var_os("HOME").context("HOME is unset")?;
            Ok(Path::new(&home).join(rest))
        }
        None => Ok(PathBuf::from(path)),
    }
}

pub fn random_hex(bytes: usize) -> anyhow::Result<String> {
    let mut buf = vec![0; bytes];
    getrandom::fill(&mut buf).map_err(|error| anyhow::anyhow!("no randomness: {error}"))?;
    Ok(buf.iter().map(|byte| format!("{byte:02x}")).collect())
}
