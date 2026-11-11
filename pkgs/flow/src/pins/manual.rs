//! Version lookups for pins that `flow pin` reports but does not rewrite.

use super::Repo;
use super::fetch;
use super::registry::Manual;
use anyhow::Context as _;
use serde::Deserialize;
use std::collections::BTreeMap;

pub struct Versions {
    pub pinned: String,
    pub latest: String,
}

pub fn versions(repo: &Repo, manual: &Manual) -> anyhow::Result<Versions> {
    match manual {
        Manual::FlakeInput {
            input,
            repo: github,
            ..
        } => {
            #[derive(Deserialize)]
            struct Lock {
                root: String,
                nodes: BTreeMap<String, Node>,
            }
            #[derive(Deserialize)]
            struct Node {
                /// Absent on the root node.
                original: Option<Original>,
                /// Node names; a `follows` input is a path array instead.
                #[serde(default)]
                inputs: BTreeMap<String, serde_json::Value>,
            }
            #[derive(Deserialize)]
            struct Original {
                #[serde(rename = "ref")]
                git_ref: Option<String>,
                rev: Option<String>,
            }
            #[derive(Deserialize)]
            struct GithubRelease {
                tag_name: String,
            }
            #[derive(Deserialize)]
            struct Comparison {
                status: String,
            }

            let path = repo.root().join("flake.lock");
            let lock: Lock = serde_json::from_slice(
                &std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?,
            )
            .with_context(|| format!("parsing {}", path.display()))?;
            // Nix may rename a node (`voxtype_2`) when another lock shares
            // its name, so resolve it through the root's input map.
            let node_name = lock
                .nodes
                .get(&lock.root)
                .and_then(|root| root.inputs.get(*input))
                .and_then(serde_json::Value::as_str)
                .with_context(|| format!("flake.lock has no direct input {input}"))?;
            let original = lock
                .nodes
                .get(node_name)
                .and_then(|node| node.original.as_ref())
                .with_context(|| format!("flake.lock has no source for input {input}"))?;
            let latest: GithubRelease = fetch::get_json(&format!(
                "https://api.github.com/repos/{github}/releases/latest"
            ))?;
            match (&original.git_ref, &original.rev) {
                (Some(tag), _) => Ok(Versions {
                    pinned: strip_v(tag.clone()),
                    latest: strip_v(latest.tag_name),
                }),
                // A commit pin carries fixes no release has yet. It stays
                // current until a release contains commits it lacks.
                (None, Some(rev)) => {
                    let comparison: Comparison = fetch::get_json(&format!(
                        "https://api.github.com/repos/{github}/compare/{}...{rev}",
                        latest.tag_name
                    ))?;
                    let pinned = rev.get(..8).unwrap_or(rev).to_owned();
                    let latest = match comparison.status.as_str() {
                        "ahead" | "identical" => pinned.clone(),
                        _ => strip_v(latest.tag_name),
                    };
                    Ok(Versions { pinned, latest })
                }
                (None, None) => {
                    anyhow::bail!("flake.lock pins neither a tag nor a commit for input {input}")
                }
            }
        }
        Manual::NpmDependency {
            package_json,
            package,
            ..
        } => {
            #[derive(Deserialize)]
            struct PackageJson {
                dependencies: BTreeMap<String, String>,
            }
            #[derive(Deserialize)]
            struct Manifest {
                version: String,
            }

            let path = repo.root().join(package_json);
            let manifest: PackageJson = serde_json::from_slice(
                &std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?,
            )
            .with_context(|| format!("parsing {}", path.display()))?;
            let pinned = manifest
                .dependencies
                .get(*package)
                .with_context(|| format!("{package_json} does not depend on {package}"))?
                .clone();
            let latest: Manifest =
                fetch::get_json(&format!("https://registry.npmjs.org/{package}/latest"))?;
            Ok(Versions {
                pinned,
                latest: latest.version,
            })
        }
    }
}

fn strip_v(tag: String) -> String {
    match tag.strip_prefix('v') {
        Some(version) => version.to_owned(),
        None => tag,
    }
}
