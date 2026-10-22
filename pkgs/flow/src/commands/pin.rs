use crate::cli::{PinArgs, PinBumpArgs, PinCommands};
use crate::context::Ctx;
use crate::logging::tracing;
use crate::pins::fetch::{self, Artifact};
use crate::pins::registry::{self, Kind, Managed, Pin};
use crate::pins::upstream::{self, Release};
use crate::pins::{PinFile, Repo, Source, manual};
use anyhow::bail;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};

#[derive(Clone, Debug, Serialize)]
pub struct PinOutput {
    pub command: &'static str,
    pub data: Vec<PinReport>,
}

impl PinOutput {
    pub fn has_failures(&self) -> bool {
        self.data
            .iter()
            .any(|report| matches!(report.status, Status::Failed { .. }))
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct PinReport {
    pub name: &'static str,
    pub pinned: Option<String>,
    pub upstream: Option<String>,
    #[serde(flatten)]
    pub status: Status,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Status {
    Current,
    Outdated,
    /// A newer release exists, but bumping it needs work this tool leaves to a person.
    ManualUpdate {
        reason: &'static str,
    },
    Bumped {
        verification: Verification,
    },
    Failed {
        error: String,
    },
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", content = "detail", rename_all = "snake_case")]
pub enum Verification {
    Built(&'static str),
    /// Only the fixed-output fetch was checked; `detail` says why no build ran.
    HashOnly(String),
}

pub fn execute(ctx: &Ctx, args: PinArgs) -> anyhow::Result<PinOutput> {
    let repo = Repo::discover(ctx.working_dir())?;
    match args.command {
        PinCommands::Check(args) => {
            let pins = select(&args.names)?;
            Ok(PinOutput {
                command: "check",
                data: pins.into_iter().map(|pin| check(&repo, pin)).collect(),
            })
        }
        PinCommands::Bump(args) => {
            let pins = select(&args.names)?;
            let system = fetch::current_system()?;
            Ok(PinOutput {
                command: "bump",
                data: pins
                    .into_iter()
                    .map(|pin| bump(&repo, pin, &args, system))
                    .collect(),
            })
        }
    }
}

/// Resolves every name before any network or file work starts.
fn select(names: &[String]) -> anyhow::Result<Vec<&'static Pin>> {
    if names.is_empty() {
        return Ok(registry::PINS.iter().collect());
    }
    let mut pins = Vec::with_capacity(names.len());
    for name in names {
        let Some(pin) = registry::find(name) else {
            let known: Vec<_> = registry::PINS.iter().map(|pin| pin.name).collect();
            bail!("unknown pin {name}; known pins: {}", known.join(", "));
        };
        if !pins.iter().any(|seen: &&Pin| seen.name == pin.name) {
            pins.push(pin);
        }
    }
    Ok(pins)
}

/// The state of one managed pin against upstream, before any hashing.
enum Comparison {
    Current,
    Outdated(Release),
}

fn compare(pinned: &PinFile, release: Release) -> anyhow::Result<Comparison> {
    let same_artifacts = release.sources.len() == pinned.sources.len()
        && release.sources.iter().all(|(system, candidate)| {
            pinned.sources.get(system).is_some_and(|source| {
                source.url == candidate.url
                    && candidate
                        .hash
                        .as_ref()
                        .is_none_or(|hash| *hash == source.hash)
            })
        });
    if release.version != pinned.version
        && version_key(&release.version) < version_key(&pinned.version)
    {
        // A stale CDN or feed mirror must not silently roll a pin back.
        bail!(
            "upstream offers {}, older than the pinned {}",
            release.version,
            pinned.version
        );
    }
    match (release.version == pinned.version, same_artifacts) {
        (true, true) => Ok(Comparison::Current),
        (false, _) => Ok(Comparison::Outdated(release)),
        // A silently replaced artifact is either a broken pin or tampering;
        // a person should look before the pin moves.
        (true, false) => bail!(
            "upstream changed the artifacts of {} without a new version",
            release.version
        ),
    }
}

/// Orders versions by their numeric runs: `2.2.4-21120` -> [2, 2, 4, 21120].
/// Every pinned upstream uses dot- or dash-separated numbers.
fn version_key(version: &str) -> Vec<u64> {
    version
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .map(|part| part.parse().unwrap_or(u64::MAX))
        .collect()
}

fn check(repo: &Repo, pin: &'static Pin) -> PinReport {
    let mut report = PinReport {
        name: pin.name,
        pinned: None,
        upstream: None,
        status: Status::Current,
    };
    let result = match &pin.kind {
        Kind::Managed(managed) => check_managed(repo, pin, managed, &mut report),
        Kind::Manual(manual_pin) => manual::versions(repo, manual_pin).map(|versions| {
            report.status = if versions.pinned == versions.latest {
                Status::Current
            } else {
                Status::ManualUpdate {
                    reason: manual_pin.reason(),
                }
            };
            report.pinned = Some(versions.pinned);
            report.upstream = Some(versions.latest);
        }),
    };
    if let Err(error) = result {
        report.status = Status::Failed {
            error: format!("{error:#}"),
        };
    }
    report
}

fn check_managed(
    repo: &Repo,
    pin: &Pin,
    managed: &Managed,
    report: &mut PinReport,
) -> anyhow::Result<()> {
    let pinned = PinFile::load(&repo.pin_path(pin.name))?;
    report.pinned = Some(pinned.version.clone());
    let release = upstream::latest(&managed.upstream, managed.artifact)?;
    report.upstream = Some(release.version.clone());
    report.status = match compare(&pinned, release)? {
        Comparison::Current => Status::Current,
        Comparison::Outdated(_) => Status::Outdated,
    };
    Ok(())
}

fn bump(repo: &Repo, pin: &'static Pin, args: &PinBumpArgs, system: &str) -> PinReport {
    let Kind::Managed(managed) = &pin.kind else {
        return check(repo, pin);
    };
    let mut report = PinReport {
        name: pin.name,
        pinned: None,
        upstream: None,
        status: Status::Current,
    };
    report.status =
        bump_managed(repo, pin, managed, args, system, &mut report).unwrap_or_else(|error| {
            Status::Failed {
                error: format!("{error:#}"),
            }
        });
    report
}

fn bump_managed(
    repo: &Repo,
    pin: &Pin,
    managed: &Managed,
    args: &PinBumpArgs,
    system: &str,
    report: &mut PinReport,
) -> anyhow::Result<Status> {
    let path = repo.pin_path(pin.name);
    let previous = PinFile::load(&path)?;
    report.pinned = Some(previous.version.clone());
    let release = upstream::latest(&managed.upstream, managed.artifact)?;
    report.upstream = Some(release.version.clone());
    let release = match compare(&previous, release)? {
        Comparison::Current => return Ok(Status::Current),
        Comparison::Outdated(release) => release,
    };
    // Every download and hash completes before the pin file changes.
    let next = PinFile {
        version: release.version,
        sources: hash_sources(release.sources, managed.artifact)?,
    };

    tracing::info!(pin = pin.name, from = %previous.version, to = %next.version, "writing pin");
    next.write_atomic(&path)?;

    let verification = match managed.flake_attr {
        None => Verification::HashOnly("the pin has no package to build".to_owned()),
        Some(_) if args.no_build => Verification::HashOnly("--no-build".to_owned()),
        Some(_) if !next.sources.contains_key(system) => {
            Verification::HashOnly(format!("the pin has no artifact for {system}"))
        }
        Some(attr) => {
            if let Err(error) = fetch::nix_build(repo.root(), attr) {
                previous.write_atomic(&path)?;
                return Err(error.context(format!(
                    "restored {} to {}",
                    path.display(),
                    previous.version
                )));
            }
            Verification::Built(attr)
        }
    };
    Ok(Status::Bumped { verification })
}

/// Fills in hashes upstream did not publish, downloading each URL once.
fn hash_sources(
    candidates: BTreeMap<String, upstream::Candidate>,
    artifact: Artifact,
) -> anyhow::Result<BTreeMap<String, Source>> {
    let mut by_url: HashMap<String, String> = HashMap::new();
    let mut sources = BTreeMap::new();
    for (system, candidate) in candidates {
        let hash = match candidate.hash {
            Some(hash) => hash,
            None => match by_url.get(&candidate.url) {
                Some(hash) => hash.clone(),
                None => {
                    let hash = fetch::prefetch(&candidate.url, artifact)?.hash;
                    by_url.insert(candidate.url.clone(), hash.clone());
                    hash
                }
            },
        };
        sources.insert(
            system,
            Source {
                url: candidate.url,
                hash,
            },
        );
    }
    Ok(sources)
}

pub fn format_text(output: &PinOutput) -> String {
    let rows: Vec<[String; 4]> = output
        .data
        .iter()
        .map(|report| {
            let status = match &report.status {
                Status::Current => "current".to_owned(),
                Status::Outdated => "outdated".to_owned(),
                Status::ManualUpdate { reason } => format!("manual: {reason}"),
                Status::Bumped {
                    verification: Verification::Built(attr),
                } => format!("bumped, built .#{attr}"),
                Status::Bumped {
                    verification: Verification::HashOnly(why),
                } => format!("bumped, not built: {why}"),
                Status::Failed { error } => format!("failed: {error}"),
            };
            [
                report.name.to_owned(),
                report.pinned.clone().unwrap_or_else(|| "?".to_owned()),
                report.upstream.clone().unwrap_or_else(|| "?".to_owned()),
                status,
            ]
        })
        .collect();
    let header = ["PIN", "PINNED", "UPSTREAM", "STATUS"].map(str::to_owned);
    let widths: [usize; 3] = std::array::from_fn(|column| {
        std::iter::once(&header)
            .chain(&rows)
            .map(|row| row[column].len())
            .max()
            .unwrap_or(0)
    });
    std::iter::once(&header)
        .chain(&rows)
        .map(|row| {
            format!(
                "{:w0$}  {:w1$}  {:w2$}  {}",
                row[0],
                row[1],
                row[2],
                row[3],
                w0 = widths[0],
                w1 = widths[1],
                w2 = widths[2],
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::{Comparison, compare};
    use crate::pins::upstream::{Candidate, Release};
    use crate::pins::{PinFile, Source};
    use std::collections::BTreeMap;

    fn pinned() -> PinFile {
        PinFile {
            version: "1.0".to_owned(),
            sources: BTreeMap::from([(
                "aarch64-darwin".to_owned(),
                Source {
                    url: "https://example.com/1.0.dmg".to_owned(),
                    hash: "sha256-old".to_owned(),
                },
            )]),
        }
    }

    fn release(version: &str, url: &str, hash: Option<&str>) -> Release {
        Release {
            version: version.to_owned(),
            sources: BTreeMap::from([(
                "aarch64-darwin".to_owned(),
                Candidate {
                    url: url.to_owned(),
                    hash: hash.map(str::to_owned),
                },
            )]),
        }
    }

    #[test]
    fn same_version_and_artifact_is_current() {
        let unhashed = release("1.0", "https://example.com/1.0.dmg", None);
        assert!(matches!(
            compare(&pinned(), unhashed).expect("compares"),
            Comparison::Current
        ));
        let hashed = release("1.0", "https://example.com/1.0.dmg", Some("sha256-old"));
        assert!(matches!(
            compare(&pinned(), hashed).expect("compares"),
            Comparison::Current
        ));
    }

    #[test]
    fn new_version_is_outdated() {
        let newer = release("1.1", "https://example.com/1.1.dmg", None);
        assert!(matches!(
            compare(&pinned(), newer).expect("compares"),
            Comparison::Outdated(_)
        ));
    }

    #[test]
    fn replaced_artifact_under_the_same_version_is_refused() {
        let replaced = release("1.0", "https://example.com/1.0.dmg", Some("sha256-new"));
        let error = compare(&pinned(), replaced).err().expect("refused");
        assert!(
            error.to_string().contains("without a new version"),
            "{error}"
        );
    }

    #[test]
    fn older_upstream_is_refused_numerically() {
        let older = release("0.9", "https://example.com/0.9.dmg", None);
        let error = compare(&pinned(), older).err().expect("refused");
        assert!(error.to_string().contains("older than"), "{error}");

        // 1.10 is newer than 1.9 even though it sorts lower as a string.
        let mut nine = pinned();
        nine.version = "1.9".to_owned();
        let ten = release("1.10", "https://example.com/1.10.dmg", None);
        assert!(matches!(
            compare(&nine, ten).expect("compares"),
            Comparison::Outdated(_)
        ));
    }
}
