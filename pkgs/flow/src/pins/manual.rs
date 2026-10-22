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
        Manual::FlakeInputTag {
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
            }
            #[derive(Deserialize)]
            struct GithubRelease {
                tag_name: String,
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
            let pinned = lock
                .nodes
                .get(node_name)
                .and_then(|node| node.original.as_ref()?.git_ref.clone())
                .with_context(|| format!("flake.lock pins no tag for input {input}"))?;
            let latest: GithubRelease = fetch::get_json(&format!(
                "https://api.github.com/repos/{github}/releases/latest"
            ))?;
            Ok(Versions {
                pinned: strip_v(pinned),
                latest: strip_v(latest.tag_name),
            })
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
