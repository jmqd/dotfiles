use crate::cli::{PinArgs, PinBumpArgs, PinCommands};
use crate::context::Ctx;
use crate::logging::tracing;
use crate::pins::cache::DmgCache;
use crate::pins::fetch::{self, Artifact};
use crate::pins::registry::{self, Kind, Managed, Pin};
use crate::pins::upstream::{self, LatestOptions, Release};
use crate::pins::{PinFile, Repo, Source, manual};
use anyhow::bail;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Mutex;

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
    let cache = Mutex::new(DmgCache::load_default());
    match args.command {
        PinCommands::Check(args) => {
            let pins = select(&args.names)?;
            let repo = &repo;
            let cache = &cache;
            let refresh = args.refresh;
            // Each check mostly waits on the network, so run them together and
            // collect in registry order.
            let data = std::thread::scope(|scope| {
                let handles: Vec<_> = pins
                    .into_iter()
                    .map(|pin| scope.spawn(move || check(repo, pin, cache, refresh)))
                    .collect();
                handles
                    .into_iter()
                    .map(|handle| {
                        handle
                            .join()
                            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
                    })
                    .collect()
            });
            Ok(PinOutput {
                command: "check",
                data,
            })
        }
        PinCommands::Bump(args) => {
            let pins = select(&args.names)?;
            let system = fetch::current_system()?;
            let repo_ref = &repo;
            let cache_ref = &cache;
            let args_ref = &args;
            // Stage 1: resolve, hash, and write each pin in parallel (each pin
            // owns its own `pins/<name>.json`).
            let outcomes: Vec<BumpOutcome> = std::thread::scope(|scope| {
                let handles: Vec<_> = pins
                    .into_iter()
                    .map(|pin| {
                        scope
                            .spawn(move || prepare_bump(repo_ref, pin, args_ref, system, cache_ref))
                    })
                    .collect();
                handles
                    .into_iter()
                    .map(|handle| {
                        handle
                            .join()
                            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
                    })
                    .collect()
            });
            // Stage 2: verify every bumped flake attr with one batched
            // `nix build`, falling back to per-attr builds on failure so only
            // broken pins roll back.
            let data =
                verify_builds_with(outcomes, |attrs| fetch::nix_build_many(repo.root(), attrs));
            Ok(PinOutput {
                command: "bump",
                data,
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

fn check(repo: &Repo, pin: &'static Pin, cache: &Mutex<DmgCache>, refresh: bool) -> PinReport {
    let mut report = PinReport {
        name: pin.name,
        pinned: None,
        upstream: None,
        status: Status::Current,
    };
    let result = match &pin.kind {
        Kind::Managed(managed) => check_managed(repo, pin, managed, cache, refresh, &mut report),
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
    cache: &Mutex<DmgCache>,
    refresh: bool,
    report: &mut PinReport,
) -> anyhow::Result<()> {
    let pinned = PinFile::load(&repo.pin_path(pin.name))?;
    report.pinned = Some(pinned.version.clone());
    let options = LatestOptions {
        pinned: Some(&pinned),
        cache: Some(cache),
        refresh,
    };
    let release = upstream::latest(&managed.upstream, managed.artifact, &options)?;
    report.upstream = Some(release.version.clone());
    report.status = match compare(&pinned, release)? {
        Comparison::Current => Status::Current,
        Comparison::Outdated(_) => Status::Outdated,
    };
    Ok(())
}

enum BumpOutcome {
    Done(PinReport),
    NeedsBuild {
        report: PinReport,
        path: PathBuf,
        previous: PinFile,
        attr: &'static str,
    },
}

fn prepare_bump(
    repo: &Repo,
    pin: &'static Pin,
    args: &PinBumpArgs,
    system: &str,
    cache: &Mutex<DmgCache>,
) -> BumpOutcome {
    let Kind::Managed(managed) = &pin.kind else {
        return BumpOutcome::Done(check(repo, pin, cache, args.refresh));
    };
    let mut report = PinReport {
        name: pin.name,
        pinned: None,
        upstream: None,
        status: Status::Current,
    };
    match prepare_bump_managed(repo, pin, managed, args, system, cache, &mut report) {
        Ok(PreparedBump::Done(status)) => {
            report.status = status;
            BumpOutcome::Done(report)
        }
        Ok(PreparedBump::NeedsBuild {
            path,
            previous,
            attr,
        }) => BumpOutcome::NeedsBuild {
            report,
            path,
            previous,
            attr,
        },
        Err(error) => {
            report.status = Status::Failed {
                error: format!("{error:#}"),
            };
            BumpOutcome::Done(report)
        }
    }
}

enum PreparedBump {
    Done(Status),
    NeedsBuild {
        path: PathBuf,
        previous: PinFile,
        attr: &'static str,
    },
}

fn prepare_bump_managed(
    repo: &Repo,
    pin: &Pin,
    managed: &Managed,
    args: &PinBumpArgs,
    system: &str,
    cache: &Mutex<DmgCache>,
    report: &mut PinReport,
) -> anyhow::Result<PreparedBump> {
    let path = repo.pin_path(pin.name);
    let previous = PinFile::load(&path)?;
    report.pinned = Some(previous.version.clone());
    let options = LatestOptions {
        pinned: Some(&previous),
        cache: Some(cache),
        refresh: args.refresh,
    };
    let release = upstream::latest(&managed.upstream, managed.artifact, &options)?;
    report.upstream = Some(release.version.clone());
    let release = match compare(&previous, release)? {
        Comparison::Current => return Ok(PreparedBump::Done(Status::Current)),
        Comparison::Outdated(release) => release,
    };
    // Every download and hash completes before the pin file changes.
    let next = PinFile {
        version: release.version,
        sources: hash_sources(release.sources, managed.artifact)?,
    };

    tracing::info!(pin = pin.name, from = %previous.version, to = %next.version, "writing pin");
    next.write_atomic(&path)?;

    match managed.flake_attr {
        None => Ok(PreparedBump::Done(Status::Bumped {
            verification: Verification::HashOnly("the pin has no package to build".to_owned()),
        })),
        Some(_) if args.no_build => Ok(PreparedBump::Done(Status::Bumped {
            verification: Verification::HashOnly("--no-build".to_owned()),
        })),
        Some(_) if !next.sources.contains_key(system) => Ok(PreparedBump::Done(Status::Bumped {
            verification: Verification::HashOnly(format!("the pin has no artifact for {system}")),
        })),
        Some(attr) => Ok(PreparedBump::NeedsBuild {
            path,
            previous,
            attr,
        }),
    }
}

fn verify_builds_with(
    outcomes: Vec<BumpOutcome>,
    mut build_fn: impl FnMut(&[&str]) -> anyhow::Result<()>,
) -> Vec<PinReport> {
    let pending_attrs: Vec<&str> = outcomes
        .iter()
        .filter_map(|outcome| match outcome {
            BumpOutcome::NeedsBuild { attr, .. } => Some(*attr),
            BumpOutcome::Done(_) => None,
        })
        .collect();

    if pending_attrs.is_empty() {
        return outcomes
            .into_iter()
            .map(|outcome| match outcome {
                BumpOutcome::Done(report) | BumpOutcome::NeedsBuild { report, .. } => report,
            })
            .collect();
    }

    let batch_result = build_fn(&pending_attrs);
    let single_pending = pending_attrs.len() == 1;
    let mut single_error = batch_result.err();

    outcomes
        .into_iter()
        .map(|outcome| match outcome {
            BumpOutcome::Done(report) => report,
            BumpOutcome::NeedsBuild {
                mut report,
                path,
                previous,
                attr,
            } => {
                let result = if single_error.is_none() {
                    Ok(())
                } else if single_pending {
                    Err(single_error.take().expect("single error present"))
                } else {
                    build_fn(&[attr])
                };
                match result {
                    Ok(()) => {
                        report.status = Status::Bumped {
                            verification: Verification::Built(attr),
                        };
                    }
                    Err(error) => {
                        let error = match previous.write_atomic(&path) {
                            Ok(()) => error.context(format!(
                                "restored {} to {}",
                                path.display(),
                                previous.version
                            )),
                            Err(restore_err) => error.context(format!(
                                "failed to restore {} to {}: {restore_err:#}",
                                path.display(),
                                previous.version
                            )),
                        };
                        report.status = Status::Failed {
                            error: format!("{error:#}"),
                        };
                    }
                }
                report
            }
        })
        .collect()
}

/// Fills in hashes upstream did not publish, downloading each unique URL once
/// in parallel.
fn hash_sources(
    candidates: BTreeMap<String, upstream::Candidate>,
    artifact: Artifact,
) -> anyhow::Result<BTreeMap<String, Source>> {
    hash_sources_with(candidates, |url| {
        fetch::prefetch(url, artifact).map(|prefetched| prefetched.hash)
    })
}

fn hash_sources_with(
    candidates: BTreeMap<String, upstream::Candidate>,
    prefetch_fn: impl Fn(&str) -> anyhow::Result<String> + Sync,
) -> anyhow::Result<BTreeMap<String, Source>> {
    let mut unique_urls: Vec<String> = Vec::new();
    for (system, candidate) in &candidates {
        // The pinned hash is whatever this URL served at bump time, so a
        // plaintext download would let anyone on the path choose it.
        if !candidate.url.starts_with("https://") {
            bail!(
                "{system}: upstream offered a non-HTTPS URL {}",
                candidate.url
            );
        }
        if candidate.hash.is_none() && !unique_urls.contains(&candidate.url) {
            unique_urls.push(candidate.url.clone());
        }
    }

    let mut by_url: HashMap<String, String> = HashMap::with_capacity(unique_urls.len());
    if unique_urls.len() == 1 {
        let url = &unique_urls[0];
        by_url.insert(url.clone(), prefetch_fn(url)?);
    } else if unique_urls.len() > 1 {
        let prefetch_ref = &prefetch_fn;
        let fetched: Vec<anyhow::Result<(String, String)>> = std::thread::scope(|scope| {
            let handles: Vec<_> = unique_urls
                .iter()
                .map(|url| {
                    scope.spawn(move || -> anyhow::Result<(String, String)> {
                        Ok((url.clone(), prefetch_ref(url)?))
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| {
                    handle
                        .join()
                        .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
                })
                .collect()
        });
        for result in fetched {
            let (url, hash) = result?;
            by_url.insert(url, hash);
        }
    }

    let mut sources = BTreeMap::new();
    for (system, candidate) in candidates {
        let hash = match candidate.hash {
            Some(hash) => hash,
            None => by_url
                .get(&candidate.url)
                .cloned()
                .expect("unique unhashed URL was prefetched"),
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
    use super::{Comparison, compare, hash_sources};
    use crate::pins::fetch::Artifact;
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

    #[test]
    fn plaintext_artifact_url_is_refused() {
        let candidates = BTreeMap::from([(
            "aarch64-darwin".to_owned(),
            Candidate {
                url: "http://example.com/1.1.dmg".to_owned(),
                hash: Some("sha256-new".to_owned()),
            },
        )]);
        let error = hash_sources(candidates, Artifact::File).expect_err("refused");
        assert!(error.to_string().contains("non-HTTPS"), "{error}");
    }

    #[test]
    fn hash_sources_deduplicates_unique_urls() {
        use super::hash_sources_with;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let calls = AtomicUsize::new(0);
        let candidates = BTreeMap::from([
            (
                "aarch64-darwin".to_owned(),
                Candidate {
                    url: "https://example.com/shared.zip".to_owned(),
                    hash: None,
                },
            ),
            (
                "x86_64-linux".to_owned(),
                Candidate {
                    url: "https://example.com/shared.zip".to_owned(),
                    hash: None,
                },
            ),
            (
                "aarch64-linux".to_owned(),
                Candidate {
                    url: "https://example.com/arm64.tar.gz".to_owned(),
                    hash: None,
                },
            ),
        ]);
        let sources = hash_sources_with(candidates, |url| {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(format!("sha256-{url}"))
        })
        .expect("hashes resolved");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            sources["aarch64-darwin"].hash,
            "sha256-https://example.com/shared.zip"
        );
        assert_eq!(
            sources["x86_64-linux"].hash,
            "sha256-https://example.com/shared.zip"
        );
        assert_eq!(
            sources["aarch64-linux"].hash,
            "sha256-https://example.com/arm64.tar.gz"
        );
    }

    #[test]
    fn batched_build_rolls_back_only_failing_pins() {
        use super::{BumpOutcome, PinReport, Status, Verification, verify_builds_with};
        use anyhow::bail;

        let dir = tempfile::tempdir().expect("tempdir");
        let good_path = dir.path().join("good.json");
        let bad_path = dir.path().join("bad.json");
        let old_good = pinned();
        let old_bad = pinned();
        let mut new_good = pinned();
        new_good.version = "2.0".to_owned();
        let mut new_bad = pinned();
        new_bad.version = "2.0".to_owned();
        new_good.write_atomic(&good_path).expect("write good");
        new_bad.write_atomic(&bad_path).expect("write bad");

        let outcomes = vec![
            BumpOutcome::NeedsBuild {
                report: PinReport {
                    name: "good",
                    pinned: Some("1.0".to_owned()),
                    upstream: Some("2.0".to_owned()),
                    status: Status::Current,
                },
                path: good_path.clone(),
                previous: old_good,
                attr: "good",
            },
            BumpOutcome::NeedsBuild {
                report: PinReport {
                    name: "bad",
                    pinned: Some("1.0".to_owned()),
                    upstream: Some("2.0".to_owned()),
                    status: Status::Current,
                },
                path: bad_path.clone(),
                previous: old_bad,
                attr: "bad",
            },
        ];

        let mut calls: Vec<Vec<String>> = Vec::new();
        let reports = verify_builds_with(outcomes, |attrs| {
            calls.push(attrs.iter().map(|s| (*s).to_owned()).collect());
            if attrs.contains(&"bad") {
                bail!("bad attr failed");
            }
            Ok(())
        });

        assert_eq!(calls, vec![vec!["good", "bad"], vec!["good"], vec!["bad"]]);
        assert!(matches!(
            reports[0].status,
            Status::Bumped {
                verification: Verification::Built("good")
            }
        ));
        assert!(matches!(reports[1].status, Status::Failed { .. }));
        assert_eq!(PinFile::load(&good_path).expect("good").version, "2.0");
        assert_eq!(PinFile::load(&bad_path).expect("bad").version, "1.0");
    }
}
