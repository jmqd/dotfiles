//! Resolves the newest upstream release of a managed pin.

use super::fetch::{self, Artifact};
use super::registry::{SparkleVersion, Upstream};
use anyhow::{Context as _, bail};
use base64::Engine as _;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Release {
    pub version: String,
    pub sources: BTreeMap<String, Candidate>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Candidate {
    pub url: String,
    /// Set when upstream metadata or resolution already proved the hash.
    pub hash: Option<String>,
}

impl Candidate {
    fn unhashed(url: String) -> Self {
        Self { url, hash: None }
    }
}

pub fn latest(upstream: &Upstream, artifact: Artifact) -> anyhow::Result<Release> {
    match upstream {
        Upstream::NpmPlatforms {
            version_package,
            packages,
        } => npm_platforms(version_package, packages),
        Upstream::GithubRelease { repo, assets } => github_release(repo, assets),
        Upstream::Sparkle { feeds, version } => {
            let mut per_system = Vec::with_capacity(feeds.len());
            for (system, feed) in *feeds {
                let xml = fetch::get(feed)?;
                let xml = String::from_utf8(xml).with_context(|| format!("{feed} is not UTF-8"))?;
                let item = newest_sparkle_item(&xml, *version)
                    .with_context(|| format!("reading appcast {feed}"))?;
                per_system.push((*system, item.version, Candidate::unhashed(item.url)));
            }
            same_version(per_system)
        }
        Upstream::WisprReleases { feeds } => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Releases {
                current_release: String,
            }
            let mut per_system = Vec::with_capacity(feeds.len());
            for (system, feed) in *feeds {
                let releases: Releases = fetch::get_json(feed)?;
                // The DMG directory sits beside RELEASES.json.
                let base = feed
                    .rsplit_once('/')
                    .map(|(base, _)| base)
                    .with_context(|| format!("{feed} has no directory"))?;
                let url = format!("{base}/dmgs/Flow-v{}.dmg", releases.current_release);
                per_system.push((*system, releases.current_release, Candidate::unhashed(url)));
            }
            same_version(per_system)
        }
        Upstream::OrbStackRedirect { system, url } => {
            let target = fetch::redirect_target(url)?;
            let version = orbstack_version(&target)?;
            Ok(Release {
                version,
                sources: BTreeMap::from([((*system).to_owned(), Candidate::unhashed(target))]),
            })
        }
        Upstream::TailscaleStable { systems } => {
            #[derive(Deserialize)]
            struct Index {
                #[serde(rename = "MacZipsVersion")]
                version: String,
                #[serde(rename = "MacZips")]
                mac: BTreeMap<String, String>,
            }
            const BASE: &str = "https://pkgs.tailscale.com/stable/";
            let index: Index = fetch::get_json(&format!("{BASE}?mode=json"))?;
            let file = index
                .mac
                .get("universal-package")
                .context("Tailscale index lists no universal macOS package")?;
            let url = format!("{BASE}{file}");
            Ok(Release {
                version: index.version,
                sources: systems
                    .iter()
                    .map(|system| ((*system).to_owned(), Candidate::unhashed(url.clone())))
                    .collect(),
            })
        }
        Upstream::UnversionedDmg {
            systems,
            url,
            info_plist,
        } => {
            // The URL never changes, so the version is only knowable from the
            // artifact itself.
            let prefetched = fetch::prefetch(url, artifact)?;
            let plist = fetch::extract_from_archive(&prefetched.store_path, info_plist)?;
            let version = bundle_short_version(&plist)
                .with_context(|| format!("reading {info_plist} from {url}"))?;
            Ok(Release {
                version,
                sources: systems
                    .iter()
                    .map(|system| {
                        (
                            (*system).to_owned(),
                            Candidate {
                                url: (*url).to_owned(),
                                hash: Some(prefetched.hash.clone()),
                            },
                        )
                    })
                    .collect(),
            })
        }
    }
}

fn npm_platforms(
    version_package: &str,
    packages: &[(&'static str, &'static str)],
) -> anyhow::Result<Release> {
    #[derive(Deserialize)]
    struct Manifest {
        version: String,
        dist: Dist,
    }
    #[derive(Deserialize)]
    struct Dist {
        tarball: String,
        integrity: String,
    }
    const REGISTRY: &str = "https://registry.npmjs.org";

    let latest: Manifest = fetch::get_json(&format!("{REGISTRY}/{version_package}/latest"))?;
    let mut sources = BTreeMap::new();
    for (system, package) in packages {
        let manifest: Manifest =
            fetch::get_json(&format!("{REGISTRY}/{package}/{}", latest.version))?;
        // npm's integrity is already an SRI string that fetchurl accepts.
        sources.insert(
            (*system).to_owned(),
            Candidate {
                url: manifest.dist.tarball,
                hash: Some(manifest.dist.integrity),
            },
        );
    }
    Ok(Release {
        version: latest.version,
        sources,
    })
}

fn github_release(repo: &str, assets: &[(&'static str, &'static str)]) -> anyhow::Result<Release> {
    #[derive(Deserialize)]
    struct GithubRelease {
        tag_name: String,
        assets: Vec<Asset>,
    }
    #[derive(Deserialize)]
    struct Asset {
        name: String,
        browser_download_url: String,
        digest: Option<String>,
    }

    let release: GithubRelease = fetch::get_json(&format!(
        "https://api.github.com/repos/{repo}/releases/latest"
    ))?;
    let version = release
        .tag_name
        .strip_prefix('v')
        .with_context(|| format!("{repo} tag {} does not start with v", release.tag_name))?
        .to_owned();
    let mut sources = BTreeMap::new();
    for (system, name) in assets {
        let asset = release
            .assets
            .iter()
            .find(|asset| asset.name == *name)
            .with_context(|| format!("{repo} {} has no asset {name}", release.tag_name))?;
        let hash = asset
            .digest
            .as_deref()
            .map(sri_from_github_digest)
            .transpose()?;
        sources.insert(
            (*system).to_owned(),
            Candidate {
                url: asset.browser_download_url.clone(),
                hash,
            },
        );
    }
    Ok(Release { version, sources })
}

/// Joins per-system results that must describe one release.
fn same_version(per_system: Vec<(&'static str, String, Candidate)>) -> anyhow::Result<Release> {
    let Some((_, version, _)) = per_system.first() else {
        bail!("pin lists no systems");
    };
    let version = version.clone();
    let mut sources = BTreeMap::new();
    for (system, system_version, candidate) in per_system {
        if system_version != version {
            bail!(
                "upstream is mid-rollout: {system} offers {system_version}, another system offers {version}"
            );
        }
        sources.insert(system.to_owned(), candidate);
    }
    Ok(Release { version, sources })
}

#[derive(Debug, Eq, PartialEq)]
struct SparkleItem {
    version: String,
    url: String,
}

const SPARKLE_NS: &str = "http://www.andymatuschak.org/xml-namespaces/sparkle";

/// Picks the item with the highest `sparkle:version` build number; feeds do
/// not promise any item order.
fn newest_sparkle_item(xml: &str, version_from: SparkleVersion) -> anyhow::Result<SparkleItem> {
    let document = roxmltree::Document::parse(xml)?;
    let mut newest: Option<(u64, SparkleItem)> = None;
    for item in document
        .descendants()
        .filter(|node| node.has_tag_name("item"))
    {
        let child_text = |name: &str| {
            item.children()
                .find(|node| node.has_tag_name((SPARKLE_NS, name)))
                .and_then(|node| node.text())
                .map(str::trim)
        };
        let build: u64 = child_text("version")
            .context("appcast item has no sparkle:version")?
            .parse()
            .context("sparkle:version is not a build number")?;
        let url = item
            .children()
            .find(|node| node.has_tag_name("enclosure"))
            .and_then(|node| node.attribute("url"))
            .context("appcast item has no enclosure URL")?
            .to_owned();
        let version = match version_from {
            SparkleVersion::ShortVersionString => child_text("shortVersionString")
                .context("appcast item has no sparkle:shortVersionString")?
                .to_owned(),
            SparkleVersion::EnclosureQuery(key) => query_param(&url, key)
                .with_context(|| format!("enclosure URL {url} has no {key} parameter"))?
                .to_owned(),
        };
        if newest.as_ref().is_none_or(|(best, _)| build > *best) {
            newest = Some((build, SparkleItem { version, url }));
        }
    }
    newest.map(|(_, item)| item).context("appcast has no items")
}

fn query_param<'a>(url: &'a str, key: &str) -> Option<&'a str> {
    let (_, query) = url.split_once('?')?;
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find_map(|(name, value)| (name == key).then_some(value))
}

/// `.../OrbStack_v2.2.4_21120_amd64.dmg` -> `2.2.4-21120`.
fn orbstack_version(url: &str) -> anyhow::Result<String> {
    let file = url.rsplit('/').next().unwrap_or(url);
    let parts = file
        .strip_prefix("OrbStack_v")
        .and_then(|rest| rest.strip_suffix(".dmg"))
        .map(|rest| rest.split('_').collect::<Vec<_>>());
    match parts.as_deref() {
        Some([version, build, _arch]) => Ok(format!("{version}-{build}")),
        _ => bail!("unexpected OrbStack download name {file}"),
    }
}

/// GitHub reports `sha256:<hex>`; Nix wants `sha256-<base64>`.
fn sri_from_github_digest(digest: &str) -> anyhow::Result<String> {
    let hex = digest
        .strip_prefix("sha256:")
        .with_context(|| format!("unsupported GitHub digest {digest}"))?;
    if hex.len() != 64 || !hex.is_ascii() {
        bail!("sha256 digest {digest} is not 64 hex digits");
    }
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| format!("sha256 digest {digest} is not hex"))?;
    Ok(format!(
        "sha256-{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

fn bundle_short_version(info_plist: &[u8]) -> anyhow::Result<String> {
    let value = plist::Value::from_reader(std::io::Cursor::new(info_plist))?;
    value
        .as_dictionary()
        .and_then(|dict| dict.get("CFBundleShortVersionString"))
        .and_then(plist::Value::as_string)
        .map(str::to_owned)
        .context("Info.plist has no CFBundleShortVersionString")
}

#[cfg(test)]
mod tests {
    use super::{
        SparkleItem, SparkleVersion, newest_sparkle_item, orbstack_version, sri_from_github_digest,
    };

    const FEED: &str = r#"<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>21161</sparkle:version>
      <sparkle:shortVersionString>26.1016.51333</sparkle:shortVersionString>
      <enclosure url="https://example.com/app?version=2.26.1&amp;branch=master" />
    </item>
    <item>
      <sparkle:version>21421</sparkle:version>
      <sparkle:shortVersionString>26.1016.61520</sparkle:shortVersionString>
      <enclosure url="https://example.com/app?version=2.26.2&amp;branch=master" />
    </item>
  </channel>
</rss>"#;

    #[test]
    fn appcast_picks_highest_build_regardless_of_order() {
        assert_eq!(
            newest_sparkle_item(FEED, SparkleVersion::ShortVersionString).expect("parses"),
            SparkleItem {
                version: "26.1016.61520".to_owned(),
                url: "https://example.com/app?version=2.26.2&branch=master".to_owned(),
            }
        );
    }

    #[test]
    fn appcast_version_can_come_from_the_enclosure_query() {
        let item =
            newest_sparkle_item(FEED, SparkleVersion::EnclosureQuery("version")).expect("parses");
        assert_eq!(item.version, "2.26.2");
    }

    #[test]
    fn orbstack_download_name_yields_version_and_build() {
        assert_eq!(
            orbstack_version("https://cdn.example/amd64/OrbStack_v2.2.4_21120_amd64.dmg")
                .expect("parses"),
            "2.2.4-21120"
        );
        assert!(orbstack_version("https://cdn.example/OrbStack.dmg").is_err());
    }

    #[test]
    fn github_digest_converts_to_nix_sri() {
        // sha256 of the empty string in both encodings.
        assert_eq!(
            sri_from_github_digest(
                "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
            .expect("converts"),
            "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        );
        assert!(sri_from_github_digest("sha512:00").is_err());
        assert!(sri_from_github_digest("sha256:zz").is_err());
    }
}
