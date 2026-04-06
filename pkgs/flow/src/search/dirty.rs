use crate::logging::tracing;
use crate::search::config::SearchConfig;
use crate::search::repo::DiscoveredRepo;
use anyhow::{Context as _, bail};
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DirtyMatch {
    pub repo: String,
    pub path: String,
    pub line: usize,
    pub snippet: String,
}

pub fn search_repo(
    config: &SearchConfig,
    git_bin: &str,
    repo: &DiscoveredRepo,
    query_terms: &[String],
    path_filter: Option<&str>,
    limit: usize,
) -> anyhow::Result<Vec<DirtyMatch>> {
    if query_terms.is_empty() {
        return Ok(Vec::new());
    }

    let dirty_files = dirty_files(git_bin, &repo.path)?;
    let mut matches = Vec::new();
    let path_filter = path_filter.map(|value| value.to_lowercase());

    for relative_path in dirty_files {
        if matches.len() >= limit {
            break;
        }

        if let Some(filter) = &path_filter {
            if !relative_path
                .to_string_lossy()
                .to_lowercase()
                .contains(filter)
            {
                continue;
            }
        }

        if relative_path
            .components()
            .any(|component| config.is_excluded_dir_name(&component.as_os_str().to_string_lossy()))
        {
            continue;
        }

        let absolute_path = repo.path.join(&relative_path);
        if !absolute_path.is_file() {
            continue;
        }

        let bytes = match fs::read(&absolute_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                tracing::debug!(path = %absolute_path.display(), error = %error, "skipping unreadable dirty file");
                continue;
            }
        };
        if bytes.contains(&0) {
            continue;
        }

        let contents = String::from_utf8_lossy(&bytes);
        for (index, line) in contents.lines().enumerate() {
            if matches.len() >= limit {
                break;
            }
            if line_matches_query(line, query_terms) {
                matches.push(DirtyMatch {
                    repo: repo.display_name.clone(),
                    path: relative_path.display().to_string(),
                    line: index + 1,
                    snippet: line.trim().to_owned(),
                });
            }
        }
    }

    Ok(matches)
}

fn dirty_files(git_bin: &str, repo_path: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut files = BTreeSet::new();
    gather_null_delimited_paths(
        git_bin,
        repo_path,
        &["diff", "--name-only", "--diff-filter=ACMR", "-z", "--"],
        &mut files,
    )?;
    gather_null_delimited_paths(
        git_bin,
        repo_path,
        &[
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=ACMR",
            "-z",
            "--",
        ],
        &mut files,
    )?;
    gather_null_delimited_paths(
        git_bin,
        repo_path,
        &["ls-files", "--others", "--exclude-standard", "-z"],
        &mut files,
    )?;

    Ok(files.into_iter().collect())
}

fn gather_null_delimited_paths(
    git_bin: &str,
    repo_path: &Path,
    args: &[&str],
    files: &mut BTreeSet<PathBuf>,
) -> anyhow::Result<()> {
    let repo_display = repo_path.display().to_string();
    let output = Command::new(git_bin)
        .arg("-C")
        .arg(&repo_display)
        .args(args)
        .output()
        .with_context(|| format!("failed to run {git_bin} for {}", repo_path.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("git command failed for {}: {stderr}", repo_path.display());
    }

    for entry in output.stdout.split(|byte| *byte == 0) {
        if entry.is_empty() {
            continue;
        }
        files.insert(PathBuf::from(String::from_utf8_lossy(entry).to_string()));
    }

    Ok(())
}

fn line_matches_query(line: &str, query_terms: &[String]) -> bool {
    let normalized_line = line.to_lowercase();
    query_terms
        .iter()
        .all(|term| normalized_line.contains(&term.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::line_matches_query;

    #[test]
    fn dirty_line_matching_requires_all_terms() {
        assert!(line_matches_query(
            "review scope parsing",
            &["review".to_owned(), "scope".to_owned()]
        ));
        assert!(!line_matches_query(
            "review parser",
            &["review".to_owned(), "scope".to_owned()]
        ));
    }
}
