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
            return Ok(current.canonicalize().unwrap_or(current));
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
    use super::{
        DiscoveredRepo, RepoRecord, discover_repos, find_repo_root, render_relative_path,
        resolve_repo_selector,
    };
    use crate::search::config::SearchConfig;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use tempfile::TempDir;

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

    #[test]
    fn discover_repos_includes_linked_worktrees_once_each() {
        let sandbox = TempDir::new().expect("tempdir");
        let root = sandbox.path().join("src");
        fs::create_dir_all(&root).expect("create root");

        let repo = init_git_repo(&root.join("project"));
        commit_file(&repo, "README.md", "main\n");

        let worktree = root.join("project-linked");
        git(
            &repo,
            &["worktree", "add", worktree.to_str().expect("utf8 path")],
        );

        let config = test_config(root.clone(), sandbox.path().join("state"));
        let repos = discover_repos(&config).expect("discovery succeeds");
        let discovered_paths = repos
            .iter()
            .map(|repo| repo.path.clone())
            .collect::<Vec<_>>();

        assert_eq!(repos.len(), 2);
        assert!(discovered_paths.contains(&repo.canonicalize().expect("canonical repo")));
        assert!(discovered_paths.contains(&worktree.canonicalize().expect("canonical worktree")));
    }

    #[test]
    fn resolve_repo_selector_reports_ambiguous_basename_across_multiple_repos() {
        let sandbox = TempDir::new().expect("tempdir");
        let root = sandbox.path().join("src");
        let state_dir = sandbox.path().join("state");
        fs::create_dir_all(root.join("alpha/shared")).expect("create alpha/shared");
        fs::create_dir_all(root.join("beta/shared")).expect("create beta/shared");
        fs::write(root.join("alpha/shared/.git"), "gitdir: /tmp/alpha\n").expect("alpha marker");
        fs::write(root.join("beta/shared/.git"), "gitdir: /tmp/beta\n").expect("beta marker");

        let config = test_config(root.clone(), state_dir);
        let error = resolve_repo_selector(&config, "shared", sandbox.path())
            .expect_err("basename should be ambiguous");

        let message = error.to_string();
        assert!(message.contains("repo selector shared is ambiguous"));
        assert!(message.contains("alpha/shared"));
        assert!(message.contains("beta/shared"));
    }

    #[test]
    fn resolve_repo_selector_prefers_manifest_records_without_discovery_fallback_when_present() {
        let sandbox = TempDir::new().expect("tempdir");
        let root = sandbox.path().join("src");
        fs::create_dir_all(&root).expect("create root");

        let repo = init_git_repo(&root.join("discovered-only"));
        commit_file(&repo, "README.md", "hello\n");

        let config = test_config(root.clone(), sandbox.path().join("state"));
        config.ensure_state_dirs().expect("state dirs");
        fs::write(
            &config.repos_manifest_path,
            serde_json::to_string(&vec![RepoRecord {
                name: "manifest-only".to_owned(),
                display_name: "manifest-only".to_owned(),
                path: sandbox
                    .path()
                    .join("indexed/manifest-only")
                    .display()
                    .to_string(),
            }])
            .expect("manifest json"),
        )
        .expect("write manifest");

        let error = resolve_repo_selector(&config, "discovered-only", sandbox.path())
            .expect_err("selector should only see manifest entries");
        assert_eq!(
            error.to_string(),
            "no indexed repo matched selector discovered-only"
        );

        let selected = resolve_repo_selector(&config, "manifest-only", sandbox.path())
            .expect("manifest selector resolves");
        assert_eq!(selected.display_name, "manifest-only");
    }

    #[test]
    fn resolve_repo_selector_falls_back_to_discovery_when_manifest_missing() {
        let sandbox = TempDir::new().expect("tempdir");
        let root = sandbox.path().join("src");
        fs::create_dir_all(&root).expect("create root");

        let repo = init_git_repo(&root.join("discovered-only"));
        commit_file(&repo, "README.md", "hello\n");

        let config = test_config(root.clone(), sandbox.path().join("state"));
        let selected = resolve_repo_selector(&config, "discovered-only", sandbox.path())
            .expect("selector resolves via discovery");

        assert_eq!(selected.display_name, "discovered-only");
        assert_eq!(selected.path, repo.canonicalize().expect("canonical repo"));
    }

    #[test]
    fn path_like_selector_that_does_not_exist_is_resolved_relative_to_cwd() {
        let sandbox = TempDir::new().expect("tempdir");
        let root = sandbox.path().join("src");
        fs::create_dir_all(&root).expect("create root");

        let repo = init_git_repo(&root.join("app"));
        commit_file(&repo, "README.md", "hello\n");
        let working_dir = repo.join("nested/current");
        fs::create_dir_all(&working_dir).expect("working dir");

        let config = test_config(root.clone(), sandbox.path().join("state"));
        let selected = resolve_repo_selector(&config, "../missing/file.rs", &working_dir)
            .expect("path-like selector should walk up from cwd-relative path");

        assert_eq!(selected.path, repo.canonicalize().expect("canonical repo"));
        assert_eq!(selected.display_name, "app");
    }

    #[test]
    fn find_repo_root_accepts_linked_worktree_git_file() {
        let sandbox = TempDir::new().expect("tempdir");
        let repo = init_git_repo(&sandbox.path().join("project"));
        commit_file(&repo, "README.md", "hello\n");
        let worktree = sandbox.path().join("project-linked");
        git(
            &repo,
            &["worktree", "add", worktree.to_str().expect("utf8 path")],
        );

        let root =
            find_repo_root(&worktree.join("src/does-not-exist.rs")).expect("repo root resolves");
        assert_eq!(root, worktree.canonicalize().expect("canonical worktree"));
    }

    fn test_config(root: PathBuf, state_dir: PathBuf) -> SearchConfig {
        let root = if root.exists() {
            root.canonicalize().expect("canonical root")
        } else {
            root
        };

        SearchConfig {
            roots: vec![root],
            zoekt_dir: state_dir.join("zoekt"),
            zoekt_index_dir: state_dir.join("zoekt/index"),
            metadata_dir: state_dir.join("metadata"),
            metadata_db_path: state_dir.join("metadata/commits.sqlite"),
            repos_manifest_path: state_dir.join("metadata/repos.json"),
            state_path: state_dir.join("state.json"),
            state_dir,
            zoekt_listen: "127.0.0.1:6070".to_owned(),
            excluded_dir_names: vec![
                ".direnv".to_owned(),
                ".git".to_owned(),
                "dist".to_owned(),
                "node_modules".to_owned(),
                "result".to_owned(),
                "target".to_owned(),
            ],
        }
    }

    fn init_git_repo(path: &Path) -> PathBuf {
        fs::create_dir_all(path).expect("create repo dir");
        git(path, &["init"]);
        git(path, &["config", "user.name", "Flow Tests"]);
        git(path, &["config", "user.email", "flow-tests@example.com"]);
        path.to_path_buf()
    }

    fn commit_file(repo: &Path, relative_path: &str, contents: &str) {
        let file_path = repo.join(relative_path);
        if let Some(parent) = file_path.parent() {
            fs::create_dir_all(parent).expect("create parent dirs");
        }
        fs::write(&file_path, contents).expect("write file");
        git(repo, &["add", relative_path]);
        git(repo, &["commit", "-m", "test commit"]);
    }

    fn git(repo: &Path, args: &[&str]) {
        let output = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(args)
            .output()
            .expect("run git command");
        assert!(
            output.status.success(),
            "git {:?} failed: stdout={} stderr={}",
            args,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
