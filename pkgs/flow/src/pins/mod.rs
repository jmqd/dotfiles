//! Manually pinned upstream artifacts.
//!
//! Each managed pin lives in `pins/<name>.json` at the dotfiles root. Nix reads
//! the file with `lib.importJSON`; `flow pin bump` is the only writer.

pub mod fetch;
pub mod manual;
pub mod registry;
pub mod upstream;

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// Nix system double, such as `aarch64-darwin`.
pub type System = &'static str;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PinFile {
    pub version: String,
    /// Keyed by Nix system so the derivation can select its own artifact.
    pub sources: BTreeMap<String, Source>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub url: String,
    /// SRI hash in the form the matching Nix fetcher expects.
    pub hash: String,
}

impl PinFile {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    pub fn render(&self) -> String {
        let mut text =
            serde_json::to_string_pretty(self).expect("PinFile has only string maps and strings");
        text.push('\n');
        text
    }

    /// Replaces `path` atomically so Nix never reads a half-written pin.
    pub fn write_atomic(&self, path: &Path) -> anyhow::Result<()> {
        let dir = path
            .parent()
            .with_context(|| format!("{} has no parent directory", path.display()))?;
        let mut temp = tempfile::NamedTempFile::new_in(dir)
            .with_context(|| format!("creating a temporary file in {}", dir.display()))?;
        temp.write_all(self.render().as_bytes())?;
        temp.as_file().sync_all()?;
        temp.persist(path)
            .with_context(|| format!("replacing {}", path.display()))?;
        Ok(())
    }
}

/// The dotfiles checkout that owns `pins/` and `flake.nix`.
#[derive(Clone, Debug)]
pub struct Repo {
    root: PathBuf,
}

impl Repo {
    /// Walks up from `start` to the first directory holding both `pins/` and
    /// `flake.nix`.
    pub fn discover(start: &Path) -> anyhow::Result<Self> {
        for dir in start.ancestors() {
            if dir.join("pins").is_dir() && dir.join("flake.nix").is_file() {
                return Ok(Self {
                    root: dir.to_path_buf(),
                });
            }
        }
        bail!(
            "no dotfiles checkout with pins/ and flake.nix above {}; run flow pin inside the dotfiles repo",
            start.display()
        )
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn pin_path(&self, name: &str) -> PathBuf {
        self.root.join("pins").join(format!("{name}.json"))
    }
}

#[cfg(test)]
mod tests {
    use super::{PinFile, Repo, Source};
    use std::collections::BTreeMap;

    fn sample() -> PinFile {
        PinFile {
            version: "1.2.3".to_owned(),
            sources: BTreeMap::from([(
                "aarch64-darwin".to_owned(),
                Source {
                    url: "https://example.com/a.dmg".to_owned(),
                    hash: "sha256-AAAA".to_owned(),
                },
            )]),
        }
    }

    #[test]
    fn written_pin_reloads_unchanged() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("demo.json");
        sample().write_atomic(&path).expect("write succeeds");
        assert_eq!(PinFile::load(&path).expect("load succeeds"), sample());
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let error = serde_json::from_str::<PinFile>(r#"{"version":"1","sources":{},"rev":"x"}"#)
            .expect_err("unknown field fails");
        assert!(error.to_string().contains("rev"), "{error}");
    }

    #[test]
    fn discovery_finds_the_checkout_from_a_subdirectory() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(dir.path().join("pins")).expect("pins dir");
        std::fs::create_dir_all(dir.path().join("pkgs/flow")).expect("nested dir");
        std::fs::write(dir.path().join("flake.nix"), "{}").expect("flake");

        let repo = Repo::discover(&dir.path().join("pkgs/flow")).expect("repo found");
        assert_eq!(repo.root(), dir.path());

        let elsewhere = tempfile::tempdir().expect("tempdir");
        assert!(Repo::discover(elsewhere.path()).is_err());
    }
}
