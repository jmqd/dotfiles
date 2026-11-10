use crate::search::config::SearchConfig;
use crate::search::repo::DiscoveredRepo;
use anyhow::{Context as _, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;
use tempfile::TempDir;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ZoektMatch {
    pub repo: String,
    pub path: String,
    pub line: Option<u32>,
    pub snippet: String,
    pub is_path_match: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ZoektReindexStats {
    pub indexed_repo_count: usize,
    /// The name zoekt gave each indexed repo, by repo path. zoekt prefers the
    /// origin remote's URL to anything flow could pass it.
    pub repo_names: BTreeMap<PathBuf, String>,
}

pub fn reindex(
    config: &SearchConfig,
    zoekt_git_index_bin: &str,
    repos: &[DiscoveredRepo],
) -> anyhow::Result<ZoektReindexStats> {
    config.ensure_state_dirs()?;
    let temporary_root = TempDir::new_in(&config.zoekt_dir).with_context(|| {
        format!(
            "failed to create temp dir in {}",
            config.zoekt_dir.display()
        )
    })?;
    let temporary_index_dir = temporary_root.path().join("index");
    fs::create_dir_all(&temporary_index_dir)
        .with_context(|| format!("failed to create {}", temporary_index_dir.display()))?;

    let mut repo_names = BTreeMap::new();
    for repo in repos {
        let repo_cache = repo.root.as_ref().unwrap_or(&repo.path);
        let index_display = temporary_index_dir.display().to_string();
        let repo_cache_display = repo_cache.display().to_string();
        let repo_display = repo.path.display().to_string();
        let before = shard_files(&temporary_index_dir)?;
        let output = Command::new(zoekt_git_index_bin)
            .arg("-index")
            .arg(&index_display)
            .arg("-repo_cache")
            .arg(&repo_cache_display)
            .arg(&repo_display)
            .output()
            .with_context(|| {
                format!(
                    "failed to run {} for {}",
                    zoekt_git_index_bin,
                    repo.path.display()
                )
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            bail!(
                "zoekt indexing failed for {}: {stderr}",
                repo.path.display()
            );
        }
        let written = shard_files(&temporary_index_dir)?
            .into_iter()
            .filter(|(file_name, identity)| before.get(file_name) != Some(identity))
            .map(|(file_name, _)| file_name);
        let name = written_repo_name(written)
            .with_context(|| format!("reading the zoekt shard for {}", repo.path.display()))?;
        repo_names.insert(repo.path.clone(), name);
    }

    if config.zoekt_index_dir.exists() {
        fs::remove_dir_all(&config.zoekt_index_dir)
            .with_context(|| format!("failed to remove {}", config.zoekt_index_dir.display()))?;
    }
    fs::rename(&temporary_index_dir, &config.zoekt_index_dir).with_context(|| {
        format!(
            "failed to move {} to {}",
            temporary_index_dir.display(),
            config.zoekt_index_dir.display()
        )
    })?;

    Ok(ZoektReindexStats {
        indexed_repo_count: repos.len(),
        repo_names,
    })
}

/// Each shard file by name, with the identity of the file behind the name.
/// zoekt writes a shard to a temp file and renames it into place, so a
/// rewritten shard has a new inode.
fn shard_files(dir: &Path) -> anyhow::Result<BTreeMap<String, (u64, SystemTime)>> {
    let mut shards = BTreeMap::new();
    for entry in fs::read_dir(dir).with_context(|| format!("failed to list {}", dir.display()))? {
        let entry = entry.with_context(|| format!("failed to list {}", dir.display()))?;
        let Ok(file_name) = entry.file_name().into_string() else {
            continue;
        };
        if !file_name.ends_with(".zoekt") {
            continue;
        }
        let metadata = entry
            .metadata()
            .with_context(|| format!("failed to stat {file_name}"))?;
        shards.insert(file_name, (metadata.ino(), metadata.modified()?));
    }
    Ok(shards)
}

/// The one repo name behind the shard files one `zoekt-git-index` run wrote.
fn written_repo_name(file_names: impl IntoIterator<Item = String>) -> anyhow::Result<String> {
    let mut names = BTreeSet::new();
    for file_name in file_names {
        let name = repo_name_from_shard(&file_name).with_context(|| {
            format!(
                "cannot recover the repo name from shard {file_name}; zoekt shortens names \
                 longer than 200 escaped bytes, so set a shorter `git config zoekt.name`"
            )
        })?;
        names.insert(name);
    }
    let mut names = names.into_iter();
    match (names.next(), names.next()) {
        (Some(name), None) => Ok(name),
        (None, _) => bail!("zoekt-git-index wrote no shard"),
        (Some(first), Some(second)) => {
            bail!("zoekt-git-index wrote shards for both {first} and {second}")
        }
    }
}

/// zoekt names a shard `<query-escaped repo name>_v<format>.<number>.zoekt`,
/// cutting escaped names over 200 bytes and appending 8 hash digits.
fn repo_name_from_shard(file_name: &str) -> Option<String> {
    let stem = file_name.strip_suffix(".zoekt")?;
    let (escaped, version) = stem.rsplit_once("_v")?;
    let (format, number) = version.split_once('.')?;
    let is_number = |value: &str| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit());
    if !is_number(format) || !is_number(number) || escaped.len() > 200 {
        return None;
    }
    query_unescape(escaped)
}

/// Reverses Go's `url.QueryEscape`.
fn query_unescape(escaped: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(escaped.len());
    let mut input = escaped.bytes();
    while let Some(byte) = input.next() {
        bytes.push(match byte {
            b'+' => b' ',
            b'%' => {
                let high = char::from(input.next()?).to_digit(16)?;
                let low = char::from(input.next()?).to_digit(16)?;
                u8::try_from(high * 16 + low).ok()?
            }
            byte => byte,
        });
    }
    String::from_utf8(bytes).ok()
}

/// `repo_filter` is the name zoekt indexed the repo under, as recorded in
/// [`ZoektReindexStats::repo_names`].
pub fn search(
    config: &SearchConfig,
    zoekt_bin: &str,
    query: &str,
    repo_filter: Option<&str>,
    path_filter: Option<&str>,
    limit: usize,
) -> anyhow::Result<Vec<ZoektMatch>> {
    if !config.index_exists()? {
        bail!(
            "Zoekt index not found at {}; run `flow search reindex` first",
            config.zoekt_index_dir.display()
        );
    }

    let index_dir = config.zoekt_index_dir.display().to_string();
    let output = Command::new(zoekt_bin)
        .args(["-jsonl", "-index_dir", &index_dir, "--", query])
        .output()
        .with_context(|| format!("failed to run {}", zoekt_bin))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("zoekt search failed: {stderr}");
    }

    let path_filter = path_filter.map(str::to_lowercase);
    let mut matches = Vec::new();

    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if line.trim().is_empty() {
            continue;
        }
        let file_match: ZoektFileMatch = serde_json::from_str(line)
            .with_context(|| format!("failed to parse zoekt result line: {line}"))?;
        if let Some(expected_repo) = repo_filter
            && file_match.repository != expected_repo
        {
            continue;
        }
        if let Some(filter) = &path_filter
            && !file_match.file_name.to_lowercase().contains(filter)
        {
            continue;
        }

        for line_match in file_match.line_matches {
            if matches.len() >= limit {
                break;
            }

            let is_path_match = line_match.file_name || line_match.line_number == 0;
            let snippet = if is_path_match {
                file_match.file_name.clone()
            } else {
                decode_snippet(&line_match.line)?
            };
            matches.push(ZoektMatch {
                repo: file_match.repository.clone(),
                path: file_match.file_name.clone(),
                line: (!is_path_match).then_some(line_match.line_number),
                snippet: snippet.trim().to_owned(),
                is_path_match,
            });
        }

        if matches.len() >= limit {
            break;
        }
    }

    Ok(matches)
}

fn decode_snippet(value: &str) -> anyhow::Result<String> {
    let bytes = BASE64_STANDARD
        .decode(value)
        .with_context(|| format!("failed to decode zoekt snippet {value}"))?;
    Ok(String::from_utf8_lossy(&bytes).to_string())
}

#[derive(Clone, Debug, Deserialize)]
struct ZoektFileMatch {
    #[serde(rename = "FileName")]
    file_name: String,
    #[serde(rename = "Repository")]
    repository: String,
    #[serde(rename = "LineMatches", default)]
    line_matches: Vec<ZoektLineMatch>,
}

#[derive(Clone, Debug, Deserialize)]
struct ZoektLineMatch {
    #[serde(rename = "Line")]
    line: String,
    #[serde(rename = "LineNumber")]
    line_number: u32,
    #[serde(rename = "FileName")]
    file_name: bool,
}

#[cfg(test)]
mod tests {
    use super::{ZoektFileMatch, decode_snippet, written_repo_name};

    #[test]
    fn decodes_base64_snippets() {
        assert_eq!(
            decode_snippet("aGVsbG8=").expect("snippet decodes"),
            "hello"
        );
    }

    #[test]
    fn parses_jsonl_file_match() {
        let parsed: ZoektFileMatch = serde_json::from_str(
            r#"{"FileName":"src/main.rs","Repository":"dotfiles","LineMatches":[{"Line":"aGVsbG8=","LineNumber":1,"FileName":false}]}"#,
        )
        .expect("json parses");
        assert_eq!(parsed.file_name, "src/main.rs");
        assert_eq!(parsed.repository, "dotfiles");
        assert_eq!(parsed.line_matches.len(), 1);
    }

    #[test]
    fn repo_name_comes_from_the_written_shards() {
        let shards = |names: &[&str]| {
            names
                .iter()
                .map(|name| (*name).to_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            written_repo_name(shards(&[
                "github.com%2Fjmqd%2Fdotfiles_v16.00000.zoekt",
                "github.com%2Fjmqd%2Fdotfiles_v16.00001.zoekt",
            ]))
            .expect("one repo"),
            "github.com/jmqd/dotfiles"
        );
        assert_eq!(
            written_repo_name(shards(&["group%2Fmy+repo_v16.00000.zoekt"])).expect("one repo"),
            "group/my repo"
        );
        assert!(written_repo_name(shards(&[])).is_err());
        assert!(written_repo_name(shards(&["a_v16.00000.zoekt", "b_v16.00000.zoekt"])).is_err());
        // zoekt cut this name and appended a hash, so it cannot be recovered.
        let shortened = format!("{}0123abcd_v16.00000.zoekt", "a".repeat(200));
        assert!(written_repo_name(shards(&[&shortened])).is_err());
    }
}
