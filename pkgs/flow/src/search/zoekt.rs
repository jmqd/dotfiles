use crate::search::config::SearchConfig;
use crate::search::repo::DiscoveredRepo;
use anyhow::{Context as _, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::Deserialize;
use std::fs;
use std::process::Command;
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

    for repo in repos {
        let repo_cache = repo.root.as_ref().unwrap_or(&repo.path);
        let index_display = temporary_index_dir.display().to_string();
        let repo_cache_display = repo_cache.display().to_string();
        let repo_display = repo.path.display().to_string();
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
    })
}

pub fn search(
    config: &SearchConfig,
    zoekt_bin: &str,
    query: &str,
    repo_filter: Option<&DiscoveredRepo>,
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
        .args(["-jsonl", "-index_dir", &index_dir, query])
        .output()
        .with_context(|| format!("failed to run {}", zoekt_bin))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("zoekt search failed: {stderr}");
    }

    let repo_filter = repo_filter.map(|repo| repo.display_name.as_str());
    let path_filter = path_filter.map(str::to_lowercase);
    let mut matches = Vec::new();

    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if line.trim().is_empty() {
            continue;
        }
        let file_match: ZoektFileMatch = serde_json::from_str(line)
            .with_context(|| format!("failed to parse zoekt result line: {line}"))?;
        if let Some(expected_repo) = repo_filter {
            if file_match.repository != expected_repo {
                continue;
            }
        }
        if let Some(filter) = &path_filter {
            if !file_match.file_name.to_lowercase().contains(filter) {
                continue;
            }
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
    use super::{ZoektFileMatch, decode_snippet};

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
}
