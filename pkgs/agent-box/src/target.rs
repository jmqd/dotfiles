//! What the user pointed agent-box at: a repository and the part of it the
//! session may write.

use anyhow::{Context as _, bail, ensure};
use percent_encoding::percent_decode_str;
use std::fmt;
use std::path::PathBuf;
use std::str::FromStr;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RepoId {
    pub owner: String,
    pub name: String,
}

impl RepoId {
    /// GitHub treats owner and repository names case-insensitively.
    pub fn is(&self, owner: &str, name: &str) -> bool {
        let name = name.strip_suffix(".git").unwrap_or(name);
        self.owner.eq_ignore_ascii_case(owner) && self.name.eq_ignore_ascii_case(name)
    }
}

impl fmt::Display for RepoId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/{}", self.owner, self.name)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Scope {
    Repo,
    Branch(String),
    Pr(u64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub repo: RepoId,
    pub scope: Scope,
}

impl Target {
    /// Workspace path relative to the work root: `owner/repo/scope`.
    /// Nesting keeps `a-b/c` and `a/b-c` apart, lowercasing matches GitHub's
    /// and APFS's case-insensitivity, and branch names are hashed in so `a/b`
    /// and `a-b` never share a checkout.
    pub fn workspace_path(&self) -> PathBuf {
        let scope = match &self.scope {
            Scope::Repo => "repo".to_owned(),
            Scope::Pr(number) => format!("pr-{number}"),
            Scope::Branch(branch) => {
                let digest = ring::digest::digest(&ring::digest::SHA256, branch.as_bytes());
                let short: String = digest.as_ref()[..4]
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect();
                format!("branch-{}-{short}", sanitize(branch))
            }
        };
        [
            self.repo.owner.to_ascii_lowercase(),
            self.repo.name.to_ascii_lowercase(),
            scope,
        ]
        .iter()
        .collect()
    }
}

fn sanitize(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

impl FromStr for Target {
    type Err = anyhow::Error;

    fn from_str(input: &str) -> anyhow::Result<Self> {
        let input = input.trim();
        let rest = [
            "https://github.com/",
            "http://github.com/",
            "ssh://git@github.com/",
            "git@github.com:",
            "github.com/",
        ]
        .iter()
        .find_map(|prefix| input.strip_prefix(prefix));
        let rest = match rest {
            Some(rest) => rest,
            None if input.contains("://") || input.contains('@') => {
                bail!("not a github.com URL: {input}")
            }
            None => input,
        };
        let rest = rest.split(['?', '#']).next().unwrap_or_default();
        let mut segments = rest.split('/').filter(|segment| !segment.is_empty());
        let (Some(owner), Some(name)) = (segments.next(), segments.next()) else {
            bail!("expected OWNER/REPO in {input}");
        };
        let name = name.strip_suffix(".git").unwrap_or(name);
        ensure!(is_github_name(owner), "invalid GitHub owner: {owner}");
        ensure!(is_github_name(name), "invalid GitHub repository: {name}");
        let repo = RepoId {
            owner: owner.to_owned(),
            name: name.to_owned(),
        };

        let scope = match segments.next() {
            None => Scope::Repo,
            Some("pull") => {
                let number = segments
                    .next()
                    .context("missing pull request number")?
                    .parse::<u64>()
                    .context("invalid pull request number")?;
                Scope::Pr(number)
            }
            Some("tree") => {
                // Branch names may contain slashes, so the rest of the path is
                // the branch; a URL that also names a file inside the tree is
                // not a branch URL.
                let raw = segments.collect::<Vec<_>>().join("/");
                let branch = percent_decode_str(&raw)
                    .decode_utf8()
                    .context("branch name is not UTF-8")?
                    .into_owned();
                ensure!(is_branch_name(&branch), "invalid branch name: {branch:?}");
                Scope::Branch(branch)
            }
            Some(other) => bail!(
                "unsupported GitHub URL path /{other}; use a repo, /tree/BRANCH, or /pull/N URL"
            ),
        };
        Ok(Self { repo, scope })
    }
}

fn is_github_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

/// The subset of `git check-ref-format` rules that matter here: the name is
/// compared against pushed refs and passed to `git clone --branch`.
fn is_branch_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with(['-', '/', '.'])
        && !name.ends_with(['/', '.'])
        && !name.ends_with(".lock")
        && !name.contains("..")
        && !name.contains("@{")
        && !name.contains("//")
        && !name
            .chars()
            .any(|c| c.is_ascii_control() || c.is_whitespace() || "~^:?*[\\".contains(c))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(input: &str) -> Target {
        input.parse().expect(input)
    }

    fn repo() -> RepoId {
        RepoId {
            owner: "jmqd".into(),
            name: "dotfiles".into(),
        }
    }

    #[test]
    fn repo_urls_in_every_common_form_name_the_same_repo() {
        for input in [
            "jmqd/dotfiles",
            "github.com/jmqd/dotfiles",
            "https://github.com/jmqd/dotfiles",
            "https://github.com/jmqd/dotfiles/",
            "https://github.com/jmqd/dotfiles.git",
            "git@github.com:jmqd/dotfiles.git",
            "ssh://git@github.com/jmqd/dotfiles",
            "https://github.com/jmqd/dotfiles?tab=readme#top",
        ] {
            assert_eq!(
                parse(input),
                Target {
                    repo: repo(),
                    scope: Scope::Repo
                },
                "{input}"
            );
        }
    }

    #[test]
    fn tree_url_scopes_to_the_whole_branch_name_including_slashes() {
        assert_eq!(
            parse("https://github.com/jmqd/dotfiles/tree/feature/agent%2Dbox").scope,
            Scope::Branch("feature/agent-box".into())
        );
    }

    #[test]
    fn pull_url_scopes_to_the_pr_even_on_a_subpage() {
        assert_eq!(
            parse("https://github.com/jmqd/dotfiles/pull/42/files").scope,
            Scope::Pr(42)
        );
    }

    #[test]
    fn other_hosts_and_unsupported_paths_are_rejected() {
        for input in [
            "https://gitlab.com/jmqd/dotfiles",
            "https://github.com/jmqd",
            "https://github.com/jmqd/dotfiles/issues/3",
            "https://github.com/jmqd/dotfiles/pull/x",
            "https://github.com/jmqd/dotfiles/tree/a..b",
            "https://github.com/jmqd/dotfiles/tree/-rf",
            "https://github.com/jmqd/../etc",
        ] {
            assert!(input.parse::<Target>().is_err(), "{input}");
        }
    }

    #[test]
    fn distinct_targets_never_share_a_workspace() {
        let targets = [
            "a-b/c",
            "a/b-c",
            "jmqd/dotfiles",
            "jmqd/dotfiles/pull/1",
            "jmqd/dotfiles/tree/a/b",
            "jmqd/dotfiles/tree/a-b",
        ];
        let paths: std::collections::HashSet<PathBuf> = targets
            .iter()
            .map(|input| parse(input).workspace_path())
            .collect();
        assert_eq!(paths.len(), targets.len());
    }

    #[test]
    fn case_variants_of_a_repo_share_one_workspace() {
        assert_eq!(
            parse("JMQD/DotFiles").workspace_path(),
            parse("jmqd/dotfiles").workspace_path()
        );
    }
}
