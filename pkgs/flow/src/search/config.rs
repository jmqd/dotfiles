use anyhow::{Context as _, bail};
use dirs::home_dir;
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

const DEFAULT_ROOTS: &[&str] = &["~/src"];
const DEFAULT_LISTEN: &str = "127.0.0.1:6070";
const DEFAULT_STATE_SUBDIR: &str = ".local/share/flow-search";
const EXCLUDED_DIRS: &[&str] = &[
    ".direnv",
    ".git",
    "dist",
    "node_modules",
    "result",
    "target",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SearchConfig {
    pub roots: Vec<PathBuf>,
    pub state_dir: PathBuf,
    pub zoekt_dir: PathBuf,
    pub zoekt_index_dir: PathBuf,
    pub metadata_dir: PathBuf,
    pub metadata_db_path: PathBuf,
    pub repos_manifest_path: PathBuf,
    pub state_path: PathBuf,
    pub zoekt_listen: String,
    pub excluded_dir_names: Vec<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct SearchState {
    pub last_reindex_at: Option<String>,
    pub repo_count: usize,
    pub commit_count: usize,
}

impl SearchConfig {
    pub fn load() -> anyhow::Result<Self> {
        let home_dir = home_dir().context("failed to determine home directory")?;

        let roots = match std::env::var_os("FLOW_SEARCH_ROOTS") {
            Some(value) => parse_root_paths(&value, &home_dir)?,
            None => DEFAULT_ROOTS
                .iter()
                .map(|root| expand_home(root, &home_dir))
                .collect::<anyhow::Result<Vec<_>>>()?,
        }
        .into_iter()
        .map(|root| {
            if root.exists() {
                root.canonicalize().unwrap_or(root)
            } else {
                root
            }
        })
        .collect();

        let state_dir = match std::env::var_os("FLOW_SEARCH_STATE_DIR") {
            Some(value) => absolutize_path(PathBuf::from(value), &home_dir)?,
            None => home_dir.join(DEFAULT_STATE_SUBDIR),
        };
        let zoekt_dir = state_dir.join("zoekt");
        let zoekt_index_dir = zoekt_dir.join("index");
        let metadata_dir = state_dir.join("metadata");
        let metadata_db_path = metadata_dir.join("commits.sqlite");
        let repos_manifest_path = metadata_dir.join("repos.json");
        let state_path = state_dir.join("state.json");
        let zoekt_listen =
            std::env::var("FLOW_SEARCH_ZOEKT_LISTEN").unwrap_or_else(|_| DEFAULT_LISTEN.to_owned());

        Ok(Self {
            roots,
            state_dir,
            zoekt_dir,
            zoekt_index_dir,
            metadata_dir,
            metadata_db_path,
            repos_manifest_path,
            state_path,
            zoekt_listen,
            excluded_dir_names: EXCLUDED_DIRS.iter().map(|dir| (*dir).to_owned()).collect(),
        })
    }

    pub fn ensure_state_dirs(&self) -> anyhow::Result<()> {
        fs::create_dir_all(&self.zoekt_index_dir)
            .with_context(|| format!("failed to create {}", self.zoekt_index_dir.display()))?;
        fs::create_dir_all(&self.metadata_dir)
            .with_context(|| format!("failed to create {}", self.metadata_dir.display()))?;
        Ok(())
    }

    pub fn load_state(&self) -> anyhow::Result<SearchState> {
        if !self.state_path.exists() {
            return Ok(SearchState::default());
        }

        let contents = fs::read_to_string(&self.state_path)
            .with_context(|| format!("failed to read {}", self.state_path.display()))?;
        serde_json::from_str(&contents)
            .with_context(|| format!("failed to parse {}", self.state_path.display()))
    }

    pub fn write_state(&self, state: &SearchState) -> anyhow::Result<()> {
        self.ensure_state_dirs()?;
        let contents = serde_json::to_string_pretty(state)?;
        fs::write(&self.state_path, contents)
            .with_context(|| format!("failed to write {}", self.state_path.display()))?;
        Ok(())
    }

    pub fn index_exists(&self) -> anyhow::Result<bool> {
        if !self.zoekt_index_dir.exists() {
            return Ok(false);
        }

        Ok(fs::read_dir(&self.zoekt_index_dir)
            .with_context(|| format!("failed to read {}", self.zoekt_index_dir.display()))?
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|extension| extension == "zoekt")
            }))
    }

    pub fn metadata_exists(&self) -> bool {
        self.metadata_db_path.exists()
    }

    pub fn is_excluded_dir_name(&self, value: &str) -> bool {
        self.excluded_dir_names.iter().any(|entry| entry == value)
    }
}

fn parse_root_paths(value: &OsString, home_dir: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut roots = Vec::new();
    for entry in std::env::split_paths(value) {
        roots.push(absolutize_path(entry, home_dir)?);
    }

    if roots.is_empty() {
        bail!("FLOW_SEARCH_ROOTS did not contain any usable paths");
    }

    Ok(roots)
}

fn absolutize_path(path: PathBuf, home_dir: &Path) -> anyhow::Result<PathBuf> {
    if path.as_os_str().is_empty() {
        bail!("search path must not be empty");
    }

    if path.is_absolute() {
        return Ok(path);
    }

    let rendered = path.to_string_lossy();
    if rendered == "~" || rendered.starts_with("~/") {
        return expand_home(&rendered, home_dir);
    }

    Ok(home_dir.join(path))
}

fn expand_home(value: &str, home_dir: &Path) -> anyhow::Result<PathBuf> {
    if value == "~" {
        return Ok(home_dir.to_path_buf());
    }

    if let Some(stripped) = value.strip_prefix("~/") {
        return Ok(home_dir.join(stripped));
    }

    let path = PathBuf::from(value);
    if path.is_absolute() {
        Ok(path)
    } else {
        bail!("expected an absolute path or ~/..., got {value}")
    }
}

#[cfg(test)]
mod tests {
    use super::SearchConfig;

    #[test]
    fn default_config_uses_src_root_and_local_state_dir() {
        let config = SearchConfig::load().expect("config loads");
        assert!(config.roots.iter().any(|root| root.ends_with("src")));
        assert!(config.state_dir.ends_with(".local/share/flow-search"));
        assert_eq!(config.zoekt_listen, "127.0.0.1:6070");
    }

    #[test]
    fn excluded_dir_defaults_include_common_generated_paths() {
        let config = SearchConfig::load().expect("config loads");
        assert!(config.is_excluded_dir_name("node_modules"));
        assert!(config.is_excluded_dir_name("target"));
        assert!(!config.is_excluded_dir_name("src"));
    }
}
