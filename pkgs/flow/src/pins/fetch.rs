//! Process boundaries for `flow pin`: curl for upstream metadata, nix for
//! hashing and building. curl uses the system trust store that
//! `home/tls.nix` and NixOS curate, which a bundled Rust TLS stack would not.

use anyhow::{Context as _, bail};
use serde::Deserialize;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};

/// How the Nix expression fetches an artifact; the hash differs per mode.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Artifact {
    /// `fetchurl` with its default name: hash of the downloaded file.
    File,
    /// `fetchzip`: hash of the unpacked tree with its single root stripped.
    /// `name` must match the fetcher's, so the prefetched path is the one the
    /// build uses.
    UnpackedZip { name: &'static str },
}

const CURL_TIMEOUT_SECS: &str = "60";

fn curl(args: &[&str], url: &str) -> anyhow::Result<Vec<u8>> {
    let mut command = Command::new("curl");
    command
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--max-time",
            CURL_TIMEOUT_SECS,
        ])
        .args(args);
    // A token raises GitHub's anonymous rate limit. Pass it on stdin so it never
    // appears in the process list.
    let token = github_token().filter(|_| url.starts_with("https://api.github.com/"));
    if token.is_some() {
        command.args(["--header", "@-"]);
    }
    command
        .arg(url)
        .stdin(if token.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn().context("running curl")?;
    if let Some(token) = token {
        let mut stdin = child.stdin.take().expect("stdin was piped above");
        writeln!(stdin, "Authorization: Bearer {token}")?;
    }
    let output = child.wait_with_output().context("waiting for curl")?;
    if !output.status.success() {
        bail!(
            "curl {url} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(output.stdout)
}

fn github_token() -> Option<String> {
    ["GITHUB_TOKEN", "GH_TOKEN"]
        .into_iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

pub fn get(url: &str) -> anyhow::Result<Vec<u8>> {
    curl(&["--location"], url)
}

pub fn get_json<T: for<'de> Deserialize<'de>>(url: &str) -> anyhow::Result<T> {
    let body = get(url)?;
    serde_json::from_slice(&body).with_context(|| format!("parsing JSON from {url}"))
}

/// Returns the `Location` of a single redirect without following it.
pub fn redirect_target(url: &str) -> anyhow::Result<String> {
    let body = curl(
        &["--output", "/dev/null", "--write-out", "%{redirect_url}"],
        url,
    )?;
    let target = String::from_utf8(body).context("redirect URL is not UTF-8")?;
    if target.is_empty() {
        bail!("{url} did not redirect");
    }
    Ok(target)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Prefetched {
    pub hash: String,
    pub store_path: String,
}

/// Downloads `url` into the Nix store and returns the hash its fetcher expects.
/// The store path matches the fetcher's output, so the build skips the download.
pub fn prefetch(url: &str, artifact: Artifact) -> anyhow::Result<Prefetched> {
    let mut command = Command::new("nix");
    command.args(["store", "prefetch-file", "--json", "--hash-type", "sha256"]);
    match artifact {
        Artifact::File => {}
        Artifact::UnpackedZip { name } => {
            command.args(["--unpack", "--name", name]);
        }
    }
    let output = command
        .arg(url)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .context("running nix store prefetch-file")?;
    if !output.status.success() {
        bail!(
            "nix store prefetch-file {url} failed with {}",
            output.status
        );
    }
    serde_json::from_slice(&output.stdout).context("parsing nix store prefetch-file output")
}
/// Reads one member of a DMG. p7zip reports header errors on current DMGs;
/// the official 7-Zip (`7zz`) reads them cleanly.
pub fn extract_from_archive(archive: &str, member: &str) -> anyhow::Result<Vec<u8>> {
    let output = Command::new("7zz")
        .args(["x", "-so", archive, member])
        .stdin(Stdio::null())
        .output()
        .context("running 7zz")?;
    if !output.status.success() || output.stdout.is_empty() {
        bail!(
            "7zz could not extract {member} from {archive}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(output.stdout)
}

pub fn nix_build(repo_root: &Path, attr: &str) -> anyhow::Result<()> {
    let installable = format!(".#{attr}");
    let status = Command::new("nix")
        .args(["build", "--no-link", &installable])
        .current_dir(repo_root)
        .stdin(Stdio::null())
        .status()
        .context("running nix build")?;
    if !status.success() {
        bail!("nix build {installable} failed with {status}");
    }
    Ok(())
}

/// The Nix system double for the running host.
pub fn current_system() -> anyhow::Result<&'static str> {
    Ok(match (std::env::consts::ARCH, std::env::consts::OS) {
        ("aarch64", "macos") => "aarch64-darwin",
        ("x86_64", "macos") => "x86_64-darwin",
        ("aarch64", "linux") => "aarch64-linux",
        ("x86_64", "linux") => "x86_64-linux",
        (arch, os) => bail!("no Nix system for {arch}-{os}"),
    })
}
