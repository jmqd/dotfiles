//! Process boundaries for `flow pin`: curl for upstream metadata, nix for
//! hashing and building. curl uses the system trust store that
//! `home/tls.nix` and NixOS curate, which a bundled Rust TLS stack would not.

use anyhow::{Context as _, bail};
use serde::Deserialize;
use std::io::{Read as _, Write as _};
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
const CURL_MAX_FILESIZE: &str = "16777216";
/// An Info.plist is a few KiB; a crafted image could expand a member without
/// bound.
const MAX_ARCHIVE_MEMBER_BYTES: u64 = 1 << 20;

fn curl(args: &[&str], url: &str) -> anyhow::Result<Vec<u8>> {
    let mut command = Command::new("curl");
    command
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--max-time",
            CURL_TIMEOUT_SECS,
            // Upstream metadata is far smaller; refuse anything larger before
            // it is buffered.
            "--max-filesize",
            CURL_MAX_FILESIZE,
            // Never fall back to plaintext, including through a redirect.
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HeadMetadata {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub content_length: Option<u64>,
}

pub fn get(url: &str) -> anyhow::Result<Vec<u8>> {
    curl(&["--location"], url)
}

pub fn head(url: &str) -> anyhow::Result<HeadMetadata> {
    let raw = curl(&["--head", "--location"], url)?;
    let text = String::from_utf8_lossy(&raw);
    Ok(parse_head_response(&text))
}

fn parse_head_response(response: &str) -> HeadMetadata {
    // Follow redirects produce multiple HTTP response blocks; only the final
    // block describes the downloaded artifact.
    let mut current = HeadMetadata::default();
    for line in response.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("HTTP/") {
            current = HeadMetadata::default();
            continue;
        }
        let Some((name, value)) = trimmed.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        if name.eq_ignore_ascii_case("etag") {
            current.etag = Some(value.to_owned());
        } else if name.eq_ignore_ascii_case("last-modified") {
            current.last_modified = Some(value.to_owned());
        } else if name.eq_ignore_ascii_case("content-length") {
            current.content_length = value.parse().ok();
        }
    }
    current
}

pub fn get_json<T: for<'de> Deserialize<'de>>(url: &str) -> anyhow::Result<T> {
    let body = get(url)?;
    serde_json::from_slice(&body).with_context(|| format!("parsing JSON from {url}"))
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
    let mut child = Command::new("7zz")
        .args(["x", "-so", archive, member])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("running 7zz")?;
    let mut contents = Vec::new();
    child
        .stdout
        .take()
        .expect("stdout was piped above")
        .take(MAX_ARCHIVE_MEMBER_BYTES + 1)
        .read_to_end(&mut contents)
        .context("reading 7zz output")?;
    if contents.len() as u64 > MAX_ARCHIVE_MEMBER_BYTES {
        // Only the error below matters; kill fails solely if 7zz already exited.
        let _ = child.kill();
        let _ = child.wait();
        bail!("{member} in {archive} is larger than {MAX_ARCHIVE_MEMBER_BYTES} bytes");
    }
    let output = child.wait_with_output().context("waiting for 7zz")?;
    if !output.status.success() || contents.is_empty() {
        bail!(
            "7zz could not extract {member} from {archive}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(contents)
}

pub fn nix_build(repo_root: &Path, attr: &str) -> anyhow::Result<()> {
    nix_build_many(repo_root, &[attr])
}

pub fn nix_build_many(repo_root: &Path, attrs: &[&str]) -> anyhow::Result<()> {
    if attrs.is_empty() {
        return Ok(());
    }
    let installables: Vec<String> = attrs.iter().map(|attr| format!(".#{attr}")).collect();
    let status = Command::new("nix")
        .args(["build", "--no-link"])
        .args(&installables)
        .current_dir(repo_root)
        .stdin(Stdio::null())
        .status()
        .context("running nix build")?;
    if !status.success() {
        bail!("nix build {} failed with {status}", installables.join(" "));
    }
    Ok(())
}

/// The Nix system double for the running host.
pub fn current_system() -> anyhow::Result<&'static str> {
    Ok(match (std::env::consts::ARCH, std::env::consts::OS) {
        ("aarch64", "macos") => "aarch64-darwin",
        ("aarch64", "linux") => "aarch64-linux",
        ("x86_64", "linux") => "x86_64-linux",
        (arch, os) => bail!("no Nix system for {arch}-{os}"),
    })
}

#[cfg(test)]
mod tests {
    use super::{HeadMetadata, parse_head_response};

    #[test]
    fn head_parser_keeps_only_final_redirect_block() {
        let raw = "\
HTTP/1.1 302 Found\r\n\
Location: https://cdn.example.com/App.dmg\r\n\
ETag: \"redirect-etag\"\r\n\
Content-Length: 0\r\n\
\r\n\
HTTP/2 200 \r\n\
etag: \"final-etag\"\r\n\
last-modified: Sat, 21 Nov 2026 18:19:29 GMT\r\n\
content-length: 173436438\r\n\
\r\n";
        assert_eq!(
            parse_head_response(raw),
            HeadMetadata {
                etag: Some("\"final-etag\"".to_owned()),
                last_modified: Some("Sat, 21 Nov 2026 18:19:29 GMT".to_owned()),
                content_length: Some(173_436_438),
            }
        );
    }
}
