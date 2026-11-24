//! Local HTTP-header cache for unversioned DMG pins (`flow pin check/bump`).
//!
//! Unversioned DMGs (such as Gemini and Spotify) serve the latest release at a
//! fixed URL, so knowing the version normally requires downloading ~170 MiB per
//! DMG and inspecting `Info.plist`. Caching `(ETag, Last-Modified,
//! Content-Length) -> (version, hash)` lets `flow pin check` skip re-downloading
//! when an HTTP `HEAD` confirms the remote artifact has not changed.

use super::fetch::HeadMetadata;
use super::{PinFile, System};
use crate::logging::tracing;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DmgCacheEntry {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub content_length: Option<u64>,
    pub version: String,
    pub hash: String,
}

impl DmgCacheEntry {
    /// Returns true when `head` carries a usable validator (`ETag` or
    /// `Last-Modified`) that matches this cached entry.
    pub fn matches_head(&self, head: &HeadMetadata) -> bool {
        if let (Some(cached_etag), Some(head_etag)) = (
            self.etag.as_deref().filter(|s| !s.is_empty()),
            head.etag.as_deref().filter(|s| !s.is_empty()),
        ) {
            if cached_etag != head_etag {
                return false;
            }
            if let (Some(cached_len), Some(head_len)) = (self.content_length, head.content_length)
                && cached_len != head_len
            {
                return false;
            }
            return true;
        }

        if let (Some(cached_mod), Some(head_mod)) = (
            self.last_modified.as_deref().filter(|s| !s.is_empty()),
            head.last_modified.as_deref().filter(|s| !s.is_empty()),
        ) {
            return cached_mod == head_mod && self.content_length == head.content_length;
        }

        false
    }

    /// Returns true when this cached entry matches the currently pinned
    /// version and hash for every system using `url`.
    pub fn matches_pinned(&self, pinned: &PinFile, systems: &[System], url: &str) -> bool {
        !systems.is_empty()
            && self.version == pinned.version
            && systems.iter().all(|system| {
                pinned
                    .sources
                    .get(*system)
                    .is_some_and(|source| source.url == url && source.hash == self.hash)
            })
    }
}

#[derive(Clone, Debug, Default)]
pub struct DmgCache {
    path: Option<PathBuf>,
    entries: BTreeMap<String, DmgCacheEntry>,
}

impl DmgCache {
    pub fn default_path() -> Option<PathBuf> {
        let base = std::env::var_os("XDG_CACHE_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| dirs::home_dir().map(|home| home.join(".cache")))?;
        Some(base.join("flow").join("pin-headers.json"))
    }

    pub fn load_default() -> Self {
        match Self::default_path() {
            Some(path) => Self::load_from(path),
            None => Self::default(),
        }
    }

    pub fn load_from(path: PathBuf) -> Self {
        let entries = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|error| {
                tracing::debug!(
                    path = %path.display(),
                    error = %error,
                    "ignoring corrupt pin header cache"
                );
                BTreeMap::new()
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(error) => {
                tracing::debug!(
                    path = %path.display(),
                    error = %error,
                    "ignoring unreadable pin header cache"
                );
                BTreeMap::new()
            }
        };
        Self {
            path: Some(path),
            entries,
        }
    }

    pub fn lookup(
        &self,
        url: &str,
        head: &HeadMetadata,
        pinned: Option<&PinFile>,
        systems: &[System],
    ) -> Option<&DmgCacheEntry> {
        let entry = self.entries.get(url)?;
        if !entry.matches_head(head) {
            return None;
        }
        let pinned = pinned?;
        if !entry.matches_pinned(pinned, systems, url) {
            return None;
        }
        Some(entry)
    }

    pub fn record(
        &mut self,
        url: &str,
        head: Option<&HeadMetadata>,
        version: String,
        hash: String,
    ) {
        let Some(head) = head else {
            return;
        };
        let has_etag = head.etag.as_deref().is_some_and(|s| !s.is_empty());
        let has_last_modified = head.last_modified.as_deref().is_some_and(|s| !s.is_empty());
        if !has_etag && !has_last_modified {
            return;
        }
        self.entries.insert(
            url.to_owned(),
            DmgCacheEntry {
                etag: head.etag.clone(),
                last_modified: head.last_modified.clone(),
                content_length: head.content_length,
                version,
                hash,
            },
        );
        if let Some(path) = &self.path
            && let Err(error) = write_entries_atomic(path, &self.entries)
        {
            tracing::debug!(
                path = %path.display(),
                error = %error,
                "failed to persist pin header cache"
            );
        }
    }
}

fn write_entries_atomic(
    path: &Path,
    entries: &BTreeMap<String, DmgCacheEntry>,
) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let dir = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no parent directory", path.display()))?;
    let mut temp = tempfile::NamedTempFile::new_in(dir)?;
    let mut encoded = serde_json::to_vec_pretty(entries)?;
    encoded.push(b'\n');
    temp.write_all(&encoded)?;
    temp.persist(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{DmgCache, DmgCacheEntry};
    use crate::pins::fetch::HeadMetadata;
    use crate::pins::{PinFile, Source};
    use std::collections::BTreeMap;

    const URL: &str = "https://example.com/App.dmg";

    fn sample_pin(version: &str, hash: &str) -> PinFile {
        PinFile {
            version: version.to_owned(),
            sources: BTreeMap::from([(
                "aarch64-darwin".to_owned(),
                Source {
                    url: URL.to_owned(),
                    hash: hash.to_owned(),
                },
            )]),
        }
    }

    #[test]
    fn etag_match_requires_matching_pinned_hash_and_version() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("flow/pin-headers.json");
        let head = HeadMetadata {
            etag: Some("\"abc\"".to_owned()),
            last_modified: Some("Wed, 18 Nov 2026 13:09:18 GMT".to_owned()),
            content_length: Some(12345),
        };

        let mut cache = DmgCache::load_from(path.clone());
        cache.record(
            URL,
            Some(&head),
            "1.2.3".to_owned(),
            "sha256-AAA".to_owned(),
        );

        let reloaded = DmgCache::load_from(path);
        let pin = sample_pin("1.2.3", "sha256-AAA");
        assert_eq!(
            reloaded.lookup(URL, &head, Some(&pin), &["aarch64-darwin"]),
            Some(&DmgCacheEntry {
                etag: head.etag.clone(),
                last_modified: head.last_modified.clone(),
                content_length: head.content_length,
                version: "1.2.3".to_owned(),
                hash: "sha256-AAA".to_owned(),
            })
        );

        let changed_etag = HeadMetadata {
            etag: Some("\"def\"".to_owned()),
            ..head.clone()
        };
        assert_eq!(
            reloaded.lookup(URL, &changed_etag, Some(&pin), &["aarch64-darwin"]),
            None
        );

        let different_pin_hash = sample_pin("1.2.3", "sha256-BBB");
        assert_eq!(
            reloaded.lookup(URL, &head, Some(&different_pin_hash), &["aarch64-darwin"]),
            None
        );

        let different_pin_version = sample_pin("1.2.4", "sha256-AAA");
        assert_eq!(
            reloaded.lookup(
                URL,
                &head,
                Some(&different_pin_version),
                &["aarch64-darwin"]
            ),
            None
        );
    }

    #[test]
    fn last_modified_fallback_checks_content_length() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut cache = DmgCache::load_from(dir.path().join("cache.json"));
        let head = HeadMetadata {
            etag: None,
            last_modified: Some("Wed, 18 Nov 2026 13:09:18 GMT".to_owned()),
            content_length: Some(500),
        };
        cache.record(URL, Some(&head), "1.0".to_owned(), "sha256-X".to_owned());
        let pin = sample_pin("1.0", "sha256-X");

        assert!(
            cache
                .lookup(URL, &head, Some(&pin), &["aarch64-darwin"])
                .is_some()
        );
        let different_len = HeadMetadata {
            content_length: Some(501),
            ..head
        };
        assert!(
            cache
                .lookup(URL, &different_len, Some(&pin), &["aarch64-darwin"])
                .is_none()
        );
    }

    #[test]
    fn corrupt_cache_file_is_ignored_cleanly() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("broken.json");
        std::fs::write(&path, b"{not json").expect("write");
        let cache = DmgCache::load_from(path);
        let head = HeadMetadata {
            etag: Some("\"x\"".to_owned()),
            last_modified: None,
            content_length: None,
        };
        assert!(
            cache
                .lookup(
                    URL,
                    &head,
                    Some(&sample_pin("1.0", "sha256-X")),
                    &["aarch64-darwin"]
                )
                .is_none()
        );
    }
}
