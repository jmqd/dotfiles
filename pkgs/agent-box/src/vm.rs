//! The colima VM and the containers that run inside it.
//!
//! The VM is the isolation boundary for files: it shares only the work root
//! with the host. Root in the VM can rewrite anything in the work root,
//! including planting symlinks, so the host writes there only into fresh,
//! randomly named directories under checked parents, and keeps its logs
//! outside it. Lima's user-mode network would otherwise let containers
//! reach the Mac's loopback services (through the host gateway) and the LAN,
//! so a firewall in the VM rejects private destinations; only the session's
//! proxy port on the host gateway is let through.

use anyhow::{Context as _, bail, ensure};
use std::io::IsTerminal as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

pub const PROFILE: &str = "agent-box";
const DOCKER_CONTEXT: &str = "colima-agent-box";
/// nixos/nix 2.32.4, pinned by its multi-arch index digest.
const IMAGE: &str =
    "nixos/nix:2.32.4@sha256:0d9c872db1ca2f3eaa4a095baa57ed9b72c09d53a0905a4428813f61f0ea98db";
/// The Nix store all sessions share. Only `realize`, which runs no repo
/// code, mounts it writable; sessions get it read-only so one repo cannot
/// plant binaries for the next.
const NIX_VOLUME: &str = "agent-box-nix";
/// Host directories the VM may see through file sharing.
const SHARE_FSTYPES: &[&str] = &["virtiofs", "9p", "fuse.sshfs"];

pub struct VmSize {
    pub cpus: u32,
    pub memory_gib: u32,
}

pub fn ensure_vm(workroot: &Path, size: &VmSize) -> anyhow::Result<()> {
    let running = Command::new("colima")
        .args(["status", "--profile", PROFILE])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("failed to run colima")?
        .success();
    if !running {
        eprintln!("agent-box: starting the {PROFILE} colima VM");
        let mut mount = workroot.as_os_str().to_owned();
        mount.push(":w");
        let status = Command::new("colima")
            .args([
                "start",
                "--profile",
                PROFILE,
                "--vm-type",
                "vz",
                "--mount-type",
                "virtiofs",
            ])
            .arg("--mount")
            .arg(mount)
            .args([
                "--cpu",
                &size.cpus.to_string(),
                "--memory",
                &size.memory_gib.to_string(),
            ])
            .status()
            .context("failed to run colima")?;
        ensure!(status.success(), "colima could not start the {PROFILE} VM");
    }
    verify_shares(workroot)?;
    install_base_rules()
}

/// Container traffic passes Docker's `DOCKER-USER` chain, which jumps to
/// ours. Replies and DNS pass; new connections to private ranges are
/// rejected. Each rule is added only if missing, so concurrent sessions and
/// reruns converge on one rule set.
const BASE_RULES: &str = r#"
set -eu
iptables -N AGENT-BOX 2>/dev/null || true
iptables -C DOCKER-USER -j AGENT-BOX 2>/dev/null || iptables -I DOCKER-USER -j AGENT-BOX
ensure() { iptables -C AGENT-BOX "$@" 2>/dev/null || iptables -A AGENT-BOX "$@"; }
ensure -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ensure -p udp --dport 53 -j RETURN
ensure -p tcp --dport 53 -j RETURN
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 127.0.0.0/8; do
  ensure -d "$net" -j REJECT
done
"#;

fn install_base_rules() -> anyhow::Result<()> {
    vm_root_script(BASE_RULES).context("could not install the VM firewall")
}

/// Runs `script` as root in the VM. It goes over stdin because ssh would
/// re-split a command-line argument.
fn vm_root_script(script: &str) -> anyhow::Result<()> {
    let mut child = Command::new("colima")
        .args(["ssh", "--profile", PROFILE, "--", "sudo", "sh", "-s"])
        .stdin(Stdio::piped())
        .spawn()
        .context("failed to run colima ssh")?;
    child
        .stdin
        .take()
        .context("colima ssh has no stdin")?
        .write_all(script.as_bytes())?;
    let status = child.wait()?;
    ensure!(status.success(), "VM command failed: {status}");
    Ok(())
}

/// Lets containers reach one proxy port on the host gateway for as long as
/// the session runs.
pub struct Firewall {
    rule: String,
}

impl Firewall {
    pub fn install(port: u16) -> anyhow::Result<Self> {
        let rule = format!(
            "-d \"$(getent ahostsv4 host.lima.internal | head -n1 | cut -d' ' -f1)\" -p tcp --dport {port} -j RETURN"
        );
        vm_root_script(&format!("set -eu; iptables -I AGENT-BOX 1 {rule}"))
            .context("could not open the proxy port in the VM firewall")?;
        Ok(Self { rule })
    }

    pub fn remove(self) {
        if let Err(error) = vm_root_script(&format!("iptables -D AGENT-BOX {}", self.rule)) {
            eprintln!("agent-box: could not close the proxy port in the VM firewall: {error:#}");
        }
    }
}

/// Checks the running VM rather than trusting flags: a profile created
/// earlier with other mounts would otherwise expose the whole home directory.
fn verify_shares(workroot: &Path) -> anyhow::Result<()> {
    let output = Command::new("colima")
        .args(["ssh", "--profile", PROFILE, "--", "cat", "/proc/mounts"])
        .stderr(Stdio::inherit())
        .output()
        .context("failed to run colima ssh")?;
    ensure!(output.status.success(), "could not read the VM's mounts");
    let mounts = String::from_utf8(output.stdout).context("VM mounts are not UTF-8")?;
    let shares = host_shares(&mounts);
    let workroot = workroot.to_str().context("work root is not UTF-8")?;
    let unexpected: Vec<&str> = shares
        .iter()
        .copied()
        .filter(|share| *share != workroot)
        .collect();
    if !unexpected.is_empty() {
        bail!(
            "the {PROFILE} VM shares more than {workroot} with the host: {}\nRecreate it with `colima delete --profile {PROFILE}`",
            unexpected.join(", ")
        );
    }
    ensure!(
        shares.contains(&workroot),
        "the {PROFILE} VM does not share {workroot}; recreate it with `colima delete --profile {PROFILE}`"
    );
    Ok(())
}

fn host_shares(mounts: &str) -> Vec<&str> {
    mounts
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let (_source, target, fstype) = (fields.next()?, fields.next()?, fields.next()?);
            SHARE_FSTYPES.contains(&fstype).then_some(target)
        })
        .collect()
}

fn docker() -> Command {
    let mut command = Command::new("docker");
    command.args(["--context", DOCKER_CONTEXT]);
    command
}

/// Copies the dotfiles flake into the work root so the VM can build from it.
/// Directories are named after the source's store path, so a copy is made
/// once per flake revision and never changes afterwards.
pub fn stage_flake(workroot: &Path, source: &Path) -> anyhow::Result<PathBuf> {
    let name = source.file_name().context("flake source has no name")?;
    let flakes = real_dir_under(workroot, Path::new(".agent-box/flakes"))?;
    let staged = flakes.join(name);
    if staged.join("flake.nix").exists() {
        return Ok(staged);
    }
    // A fresh, randomly named directory: nothing in the VM can have planted
    // a symlink at the copy's destination.
    let partial = tempfile::Builder::new()
        .prefix(".partial-")
        .tempdir_in(&flakes)
        .context("could not create a staging directory")?;
    let copy = partial.path().join("flake");
    let status = Command::new("cp")
        .arg("-R")
        .arg(source)
        .arg(&copy)
        .status()
        .context("failed to run cp")?;
    ensure!(
        status.success(),
        "could not copy {} into the work root",
        source.display()
    );
    std::fs::rename(&copy, &staged).context("could not finish staging the flake")?;
    Ok(staged)
}

/// Creates `workroot/relative` and checks that no component under the work
/// root is a symlink. Root in the VM can write anywhere in the work root, so
/// a planted symlink would otherwise steer host writes outside it.
pub fn real_dir_under(workroot: &Path, relative: &Path) -> anyhow::Result<PathBuf> {
    let path = workroot.join(relative);
    std::fs::create_dir_all(&path)?;
    let mut current = workroot.to_path_buf();
    for component in relative.components() {
        current.push(component);
        let metadata = std::fs::symlink_metadata(&current)?;
        ensure!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "{} is not a plain directory; something in the VM replaced it",
            current.display()
        );
    }
    Ok(path)
}

/// Builds or downloads `installables` into the shared store, from a
/// container that sees only the staged flake. Returns their store paths.
pub fn realize(flake: &Path, installables: &[String]) -> anyhow::Result<Vec<String>> {
    eprintln!("agent-box: preparing {} packages", installables.len());
    let mut flake_mount = flake.as_os_str().to_owned();
    flake_mount.push(":/flake:ro");
    let output = docker()
        .args([
            "run",
            "--rm",
            "--volume",
            &format!("{NIX_VOLUME}:/nix"),
            "--volume",
        ])
        .arg(flake_mount)
        .args(["--env", "NIXPKGS_ALLOW_UNFREE=1", IMAGE])
        .args([
            "nix",
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--impure",
            "--no-link",
            "--print-out-paths",
            "--inputs-from",
            "/flake",
        ])
        .args(installables)
        .stderr(Stdio::inherit())
        .output()
        .context("failed to run docker")?;
    ensure!(
        output.status.success(),
        "building the session's packages failed"
    );
    let paths = String::from_utf8(output.stdout).context("nix printed non-UTF-8 paths")?;
    Ok(paths.lines().map(str::to_owned).collect())
}

pub struct Session<'a> {
    pub name: String,
    pub workspace: &'a Path,
    /// Host-written session files, mounted read-only at /run/agent-box.
    pub control: &'a Path,
    pub env: Vec<(String, String)>,
    /// Host variables copied into the container by name.
    pub pass_env: &'a [String],
    /// Runs in the repo instead of an interactive shell when not empty.
    pub command: &'a [String],
}

pub async fn run_session(session: Session<'_>) -> anyhow::Result<ExitStatus> {
    let mut work_mount = session.workspace.as_os_str().to_owned();
    work_mount.push(":/work");
    let mut control_mount = session.control.as_os_str().to_owned();
    control_mount.push(":/run/agent-box:ro");
    let mut command = docker();
    command.args(["run", "--rm", "--interactive"]);
    if std::io::stdin().is_terminal() {
        command.arg("--tty");
    }
    command
        .args(["--name", &session.name, "--hostname", "agent-box"])
        .args(["--security-opt", "no-new-privileges"])
        .args(["--volume", &format!("{NIX_VOLUME}:/nix:ro"), "--volume"])
        .arg(work_mount)
        .arg("--volume")
        .arg(control_mount)
        .args(["--workdir", "/work"]);
    for (key, value) in &session.env {
        command.arg("--env").arg(format!("{key}={value}"));
    }
    for key in session.pass_env {
        command.arg("--env").arg(key);
    }
    command
        .args([IMAGE, "sh", "/run/agent-box/init.sh"])
        .args(session.command);
    let status = tokio::process::Command::from(command)
        .status()
        .await
        .context("failed to run docker")?;
    Ok(status)
}
