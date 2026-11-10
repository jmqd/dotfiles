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

/// `query_terms` must already be lowercase, as `normalize_query_terms`
/// returns them.
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

        if let Some(filter) = &path_filter
            && !relative_path
                .to_string_lossy()
                .to_lowercase()
                .contains(filter)
        {
            continue;
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
        // Lowercasing never adds or removes a line break, so the lowercased
        // lines pair up one to one with the original ones.
        let lowercase = contents.to_lowercase();
        if !contains_all_terms(&lowercase, query_terms) {
            continue;
        }
        for (index, (line, lowercase_line)) in contents.lines().zip(lowercase.lines()).enumerate() {
            if matches.len() >= limit {
                break;
            }
            if contains_all_terms(lowercase_line, query_terms) {
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

fn dirty_files(git_bin: &str, repo_path: &Path) -> anyhow::Result<BTreeSet<PathBuf>> {
    let output = Command::new(git_bin)
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(repo_path)
        .args([
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--no-renames",
        ])
        .output()
        .with_context(|| format!("failed to run {git_bin} for {}", repo_path.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("git status failed for {}: {stderr}", repo_path.display());
    }
    Ok(parse_porcelain(&output.stdout))
}

/// Paths whose working copy may hold new text: the union of
/// `git diff --diff-filter=ACMR`, the same with `--cached`, and
/// `git ls-files --others --exclude-standard`. Type changes and deletions are
/// left out, as that filter leaves them out. Every conflicted path is kept;
/// `git diff` lists one only when it differs from our side, which holds for
/// any file with conflict markers.
fn parse_porcelain(output: &[u8]) -> BTreeSet<PathBuf> {
    let mut files = BTreeSet::new();
    let mut entries = output.split(|byte| *byte == 0);
    while let Some(entry) = entries.next() {
        let [index, worktree, b' ', path @ ..] = entry else {
            continue;
        };
        // A rename or copy carries its source path as the next field.
        if matches!(index, b'R' | b'C') {
            entries.next();
        }
        let has_new_text = |status: u8| matches!(status, b'A' | b'C' | b'M' | b'R' | b'U');
        if *index == b'?' || has_new_text(*index) || has_new_text(*worktree) {
            files.insert(PathBuf::from(String::from_utf8_lossy(path).into_owned()));
        }
    }
    files
}

fn contains_all_terms(lowercase_text: &str, query_terms: &[String]) -> bool {
    query_terms
        .iter()
        .all(|term| lowercase_text.contains(term.as_str()))
}

#[cfg(test)]
mod tests {
    use super::{contains_all_terms, parse_porcelain};
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    #[test]
    fn dirty_text_matching_requires_all_terms() {
        let terms = ["review".to_owned(), "scope".to_owned()];
        assert!(contains_all_terms("review scope parsing", &terms));
        assert!(!contains_all_terms("review parser", &terms));
    }

    #[test]
    fn porcelain_keeps_paths_with_new_content() {
        let output = [
            "M  staged-modified",
            " M unstaged-modified",
            "MM both-modified",
            "A  staged-added",
            "AM added-then-edited",
            " T unstaged-type-change",
            "?? untracked/file",
            "D  staged-deleted",
            " D unstaged-deleted",
            "MD modified-then-deleted",
            "R  renamed-to\0renamed-from",
            "C  copied-to\0copied-from",
            "UU both-modified-conflict",
            "AA both-added-conflict",
            "DD both-deleted-conflict",
            "AU added-by-us-conflict",
            "UD deleted-by-them-conflict",
            "!! ignored",
        ]
        .map(|entry| format!("{entry}\0"))
        .concat();
        let expected: BTreeSet<PathBuf> = [
            "staged-modified",
            "unstaged-modified",
            "both-modified",
            "staged-added",
            "added-then-edited",
            "untracked/file",
            "modified-then-deleted",
            "renamed-to",
            "copied-to",
            "both-modified-conflict",
            "both-added-conflict",
            "added-by-us-conflict",
            "deleted-by-them-conflict",
        ]
        .into_iter()
        .map(PathBuf::from)
        .collect();
        assert_eq!(parse_porcelain(output.as_bytes()), expected);
    }
}
