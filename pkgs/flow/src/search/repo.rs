use crate::logging::tracing;
use crate::search::config::SearchConfig;
use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use walkdir::WalkDir;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RepoRecord {
    pub name: String,
    pub display_name: String,
    pub path: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveredRepo {
    pub name: String,
    pub display_name: String,
    pub path: PathBuf,
    pub root: Option<PathBuf>,
}

impl DiscoveredRepo {
    pub fn from_path(config: &SearchConfig, path: PathBuf) -> Self {
        let normalized_path = path.canonicalize().unwrap_or(path);
        let root = config
            .roots
            .iter()
            .filter(|candidate| normalized_path.starts_with(candidate))
            .max_by_key(|candidate| candidate.components().count())
            .cloned();
        let display_name = root
            .as_ref()
            .and_then(|root_path| normalized_path.strip_prefix(root_path).ok())
            .map(render_relative_path)
            .unwrap_or_else(|| {
                normalized_path
                    .file_name()
                    .map(|value| value.to_string_lossy().to_string())
                    .unwrap_or_else(|| normalized_path.display().to_string())
            });
        let name = normalized_path
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| display_name.clone());

        Self {
            name,
            display_name,
            path: normalized_path,
            root,
        }
    }

    pub fn to_record(&self) -> RepoRecord {
        RepoRecord {
            name: self.name.clone(),
            display_name: self.display_name.clone(),
            path: self.path.display().to_string(),
        }
    }
}

pub fn discover_repos(config: &SearchConfig) -> anyhow::Result<Vec<DiscoveredRepo>> {
    let mut repos = Vec::new();
    let mut seen = BTreeSet::new();

    for configured_root in &config.roots {
        if !configured_root.exists() {
            continue;
        }

        let root = configured_root
            .canonicalize()
            .unwrap_or_else(|_| configured_root.clone());
        let mut entries = WalkDir::new(&root).follow_links(false).into_iter();

        while let Some(entry) = entries.next() {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    tracing::debug!(error = %error, "skipping repo discovery walk error");
                    continue;
                }
            };

            if entry.file_type().is_dir() {
                let file_name = entry.file_name().to_string_lossy();
                if entry.depth() > 0
                    && file_name.as_ref() != ".git"
                    && config.is_excluded_dir_name(&file_name)
                {
                    entries.skip_current_dir();
                    continue;
                }
            }

            if entry.file_name() != ".git" {
                continue;
            }

            let Some(parent) = entry.path().parent() else {
                continue;
            };
            let repo_path = parent
                .canonicalize()
                .unwrap_or_else(|_| parent.to_path_buf());
            if seen.insert(repo_path.clone()) {
                repos.push(DiscoveredRepo::from_path(config, repo_path));
            }

            if entry.file_type().is_dir() {
                entries.skip_current_dir();
            }
        }
    }

    repos.sort_by(|left, right| left.display_name.cmp(&right.display_name));
    Ok(repos)
}

pub fn load_repo_records(config: &SearchConfig) -> anyhow::Result<Vec<DiscoveredRepo>> {
    if !config.repos_manifest_path.exists() {
        return Ok(Vec::new());
    }

    let contents = fs::read_to_string(&config.repos_manifest_path)
        .with_context(|| format!("failed to read {}", config.repos_manifest_path.display()))?;
    let records: Vec<RepoRecord> = serde_json::from_str(&contents)
        .with_context(|| format!("failed to parse {}", config.repos_manifest_path.display()))?;

    Ok(records
        .into_iter()
        .map(|record| DiscoveredRepo {
            name: record.name,
            display_name: record.display_name,
            path: PathBuf::from(record.path),
            root: None,
        })
        .collect())
}

pub fn write_repo_records(config: &SearchConfig, repos: &[DiscoveredRepo]) -> anyhow::Result<()> {
    config.ensure_state_dirs()?;
    let records = repos
        .iter()
        .map(DiscoveredRepo::to_record)
        .collect::<Vec<_>>();
    let contents = serde_json::to_string_pretty(&records)?;
    fs::write(&config.repos_manifest_path, contents)
        .with_context(|| format!("failed to write {}", config.repos_manifest_path.display()))?;
    Ok(())
}

pub fn resolve_repo_selector(
    config: &SearchConfig,
    selector: &str,
    working_dir: &Path,
) -> anyhow::Result<DiscoveredRepo> {
    if selector.starts_with('/')
        || selector.starts_with('~')
        || selector.starts_with('.')
        || selector.contains('/')
    {
        let path = if selector == "~" || selector.starts_with("~/") {
            let home = dirs::home_dir().context("failed to determine home directory")?;
            if selector == "~" {
                home
            } else {
                home.join(selector.trim_start_matches("~/"))
            }
        } else {
            let path = PathBuf::from(selector);
            if path.is_absolute() {
                path
            } else {
                working_dir.join(path)
            }
        };

        let repo_path = find_repo_root(&path).with_context(|| {
            format!(
                "failed to resolve git repo from selector {}",
                path.display()
            )
        })?;
        return Ok(DiscoveredRepo::from_path(config, repo_path));
    }

    let mut candidates = load_repo_records(config)?;
    if candidates.is_empty() {
        candidates = discover_repos(config)?;
    }

    if let Some(repo) = candidates
        .iter()
        .find(|repo| repo.display_name == selector)
        .cloned()
    {
        return Ok(repo);
    }

    let basename_matches = candidates
        .into_iter()
        .filter(|repo| repo.name == selector)
        .collect::<Vec<_>>();
    match basename_matches.as_slice() {
        [repo] => Ok(repo.clone()),
        [] => bail!("no indexed repo matched selector {selector}"),
        _ => {
            let options = basename_matches
                .iter()
                .map(|repo| repo.display_name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            bail!("repo selector {selector} is ambiguous; use one of: {options}")
        }
    }
}

pub fn repo_from_working_dir(config: &SearchConfig, working_dir: &Path) -> Option<DiscoveredRepo> {
    find_repo_root(working_dir)
        .ok()
        .map(|path| DiscoveredRepo::from_path(config, path))
}

pub fn repo_has_head(git_bin: &str, repo_path: &Path) -> bool {
    Command::new(git_bin)
        .args([
            "-C",
            &repo_path.display().to_string(),
            "rev-parse",
            "--verify",
            "HEAD^{commit}",
        ])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn find_repo_root(path: &Path) -> anyhow::Result<PathBuf> {
    let absolute = if path.exists() {
        path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
    } else {
        path.to_path_buf()
    };

    let mut candidate = if absolute.is_file() {
        absolute.parent().map(Path::to_path_buf)
    } else {
        Some(absolute)
    };

    while let Some(current) = candidate {
        if current.join(".git").exists() {
            return Ok(current);
        }
        candidate = current.parent().map(Path::to_path_buf);
    }

    bail!("path {} is not inside a git repository", path.display())
}

fn render_relative_path(path: &Path) -> String {
    let rendered = path.display().to_string();
    rendered.trim_start_matches('/').to_owned()
}

#[cfg(test)]
mod tests {
    use super::{DiscoveredRepo, render_relative_path};
    use crate::search::config::SearchConfig;
    use std::path::PathBuf;

    #[test]
    fn repo_from_path_uses_relative_display_name_when_under_root() {
        let config = SearchConfig::load().expect("config loads");
        let repo = DiscoveredRepo::from_path(&config, PathBuf::from("/tmp/root/group/repo"));
        assert!(!repo.display_name.is_empty());
        assert_eq!(repo.name, "repo");
    }

    #[test]
    fn relative_path_rendering_strips_leading_slash() {
        assert_eq!(
            render_relative_path(PathBuf::from("/group/repo").as_path()),
            "group/repo"
        );
        assert_eq!(
            render_relative_path(PathBuf::from("repo").as_path()),
            "repo"
        );
    }
}
