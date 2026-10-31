//! Append-only sample log: one JSON line per sample in `<dir>/<UTC date>.jsonl`.
//! Finished days are gzipped to `<UTC date>.jsonl.gz` (about a tenth of the
//! size) rather than deleted; deleting old days is opt-in through `prune`.

use super::Sample;
use anyhow::Context as _;
use chrono::{DateTime, Days, NaiveDate, Utc};
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};

/// The service writes to the system log directory on Linux; on macOS the
/// sampler runs as the user.
pub fn default_dir() -> Option<PathBuf> {
    if cfg!(target_os = "macos") {
        dirs::home_dir().map(|home| home.join("Library/Logs/flow-thermal"))
    } else if cfg!(target_os = "linux") {
        Some(PathBuf::from("/var/log/flow-thermal"))
    } else {
        None
    }
}

/// How far back from the end of a day file to look for the newest sample.
const TAIL_BYTES: u64 = 64 * 1024;

/// One day's samples. A day is `Gzip` once its compressed copy is complete,
/// even if a crash left the plain file behind.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum DayFile {
    Plain(PathBuf),
    Gzip(PathBuf),
}

impl DayFile {
    fn read(&self) -> anyhow::Result<Vec<u8>> {
        match self {
            Self::Plain(path) => match fs::read(path) {
                // Compressed between listing and reading.
                Err(error) if error.kind() == ErrorKind::NotFound => {
                    Self::Gzip(gzip_path(path)).read()
                }
                result => result.with_context(|| format!("reading {}", path.display())),
            },
            Self::Gzip(path) => {
                let mut bytes = Vec::new();
                File::open(path)
                    .and_then(|file| GzDecoder::new(file).read_to_end(&mut bytes))
                    .with_context(|| format!("reading {}", path.display()))?;
                Ok(bytes)
            }
        }
    }

    fn latest(&self) -> anyhow::Result<Option<Sample>> {
        let Self::Plain(path) = self else {
            return Ok(newest_parsable(&self.read()?));
        };
        let mut file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                return Self::Gzip(gzip_path(path)).latest();
            }
            Err(error) => return Err(error).with_context(|| format!("opening {}", path.display())),
        };
        let start = file.metadata()?.len().saturating_sub(TAIL_BYTES);
        let mut tail = Vec::new();
        file.seek(SeekFrom::Start(start))?;
        file.read_to_end(&mut tail)?;
        match newest_parsable(&tail) {
            Some(sample) => Ok(Some(sample)),
            None if start == 0 => Ok(None),
            // A line longer than the tail window; fall back to the whole file.
            None => Ok(newest_parsable(&self.read()?)),
        }
    }
}

fn gzip_path(plain: &Path) -> PathBuf {
    let mut name = plain.as_os_str().to_owned();
    name.push(".gz");
    PathBuf::from(name)
}

#[derive(Clone, Debug)]
pub struct ThermalLog {
    dir: PathBuf,
}

impl ThermalLog {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Appends one line with a single write, so concurrent readers see at
    /// most a torn final line, which they skip.
    pub fn append(&self, sample: &Sample) -> anyhow::Result<PathBuf> {
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        let path = self.day_file(sample.at.date_naive());
        let mut line = serde_json::to_vec(sample)?;
        line.push(b'\n');
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut file| file.write_all(&line))
            .with_context(|| format!("appending to {}", path.display()))?;
        Ok(path)
    }

    pub fn latest(&self) -> anyhow::Result<Option<Sample>> {
        for (_, file) in self.days()?.into_iter().rev() {
            if let Some(sample) = file.latest()? {
                return Ok(Some(sample));
            }
        }
        Ok(None)
    }

    /// Samples taken at or after `start`, oldest first.
    pub fn since(&self, start: DateTime<Utc>) -> anyhow::Result<Vec<Sample>> {
        let mut samples = Vec::new();
        for (day, file) in self.days()? {
            if day < start.date_naive() {
                continue;
            }
            let bytes = file.read()?;
            samples.extend(
                bytes
                    .split(|byte| *byte == b'\n')
                    .filter_map(|line| serde_json::from_slice::<Sample>(line).ok())
                    .filter(|sample| sample.at >= start),
            );
        }
        Ok(samples)
    }

    /// Gzips every plain day file before `today` and returns the compressed
    /// files. The plain file is removed only after its compressed copy is
    /// fully written and renamed into place.
    pub fn compress_finished(&self, today: NaiveDate) -> anyhow::Result<Vec<PathBuf>> {
        let mut compressed = Vec::new();
        for (day, file) in self.days()? {
            if day >= today {
                continue;
            }
            let plain = self.day_file(day);
            if let DayFile::Plain(_) = file {
                let target = gzip_path(&plain);
                let partial = self.dir.join(format!("{day}.jsonl.gz.partial"));
                write_gzip(&plain, &partial)
                    .and_then(|()| fs::rename(&partial, &target))
                    .with_context(|| format!("compressing {}", plain.display()))?;
                compressed.push(target);
            }
            match fs::remove_file(&plain) {
                Err(error) if error.kind() != ErrorKind::NotFound => {
                    return Err(error).with_context(|| format!("removing {}", plain.display()));
                }
                _ => {}
            }
        }
        Ok(compressed)
    }

    /// Deletes days older than the newest `keep_days` days ending at
    /// `today`, and returns them.
    pub fn prune(&self, keep_days: u32, today: NaiveDate) -> anyhow::Result<Vec<PathBuf>> {
        let Some(oldest_kept) = today.checked_sub_days(Days::new(u64::from(keep_days.max(1)) - 1))
        else {
            return Ok(Vec::new());
        };
        let mut removed = Vec::new();
        for (day, _) in self.days()? {
            if day >= oldest_kept {
                continue;
            }
            for path in [self.day_file(day), gzip_path(&self.day_file(day))] {
                match fs::remove_file(&path) {
                    Ok(()) => removed.push(path),
                    Err(error) if error.kind() == ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(error).with_context(|| format!("removing {}", path.display()));
                    }
                }
            }
        }
        Ok(removed)
    }

    fn day_file(&self, day: NaiveDate) -> PathBuf {
        self.dir.join(format!("{day}.jsonl"))
    }

    /// One file per day, oldest first; a missing directory has none.
    fn days(&self) -> anyhow::Result<Vec<(NaiveDate, DayFile)>> {
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(error).with_context(|| format!("listing {}", self.dir.display()));
            }
        };
        // `Gzip` sorts after `Plain`, so `max` prefers the compressed copy.
        let mut days: BTreeMap<NaiveDate, DayFile> = BTreeMap::new();
        for entry in entries {
            let path = entry?.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            let parsed = if let Some(stem) = name.strip_suffix(".jsonl.gz") {
                stem.parse()
                    .ok()
                    .map(|day| (day, DayFile::Gzip(path.clone())))
            } else if let Some(stem) = name.strip_suffix(".jsonl") {
                stem.parse()
                    .ok()
                    .map(|day| (day, DayFile::Plain(path.clone())))
            } else {
                None
            };
            if let Some((day, file)) = parsed {
                let best = match days.remove(&day) {
                    Some(existing) => existing.max(file),
                    None => file,
                };
                days.insert(day, best);
            }
        }
        Ok(days.into_iter().collect())
    }
}

fn write_gzip(source: &Path, target: &Path) -> io::Result<()> {
    let mut encoder = GzEncoder::new(File::create(target)?, Compression::default());
    io::copy(&mut File::open(source)?, &mut encoder)?;
    encoder.finish()?.sync_all()
}

fn newest_parsable(bytes: &[u8]) -> Option<Sample> {
    bytes
        .split(|byte| *byte == b'\n')
        .rev()
        .find_map(|line| serde_json::from_slice(line).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::thermal::{Kind, Reading, Source};
    use chrono::TimeZone as _;

    fn sample(at: DateTime<Utc>, value: f64) -> Sample {
        Sample {
            at,
            readings: vec![Reading {
                source: Source::Os,
                sensor: "k10temp Tctl".to_owned(),
                kind: Kind::TempC,
                value,
                limit: Some(90.0),
                bmc_status: None,
                alert: false,
            }],
            errors: Vec::new(),
        }
    }

    fn at(day: u32, hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, day, hour, 0, 0)
            .single()
            .expect("valid time")
    }

    fn names(paths: &[PathBuf]) -> Vec<&str> {
        paths
            .iter()
            .filter_map(|path| path.file_name()?.to_str())
            .collect()
    }

    #[test]
    fn reads_back_samples_across_days_and_skips_a_torn_line() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = ThermalLog::new(dir.path().join("thermal"));
        assert_eq!(log.latest().expect("latest"), None);

        let samples = [
            sample(at(29, 23), 50.0),
            sample(at(30, 1), 60.0),
            sample(at(30, 2), 70.0),
        ];
        for sample in &samples {
            log.append(sample).expect("append");
        }
        // A writer killed mid-line leaves a partial record at the end.
        let mut file = OpenOptions::new()
            .append(true)
            .open(log.day_file(at(30, 0).date_naive()))
            .expect("open");
        file.write_all(b"{\"at\":\"2026-10-30T03").expect("write");

        assert_eq!(log.latest().expect("latest").as_ref(), Some(&samples[2]));
        assert_eq!(log.since(at(30, 1)).expect("since"), samples[1..]);
        assert_eq!(log.since(at(29, 0)).expect("since"), samples);
    }

    #[test]
    fn finished_days_are_compressed_and_still_read_back() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = ThermalLog::new(dir.path().to_owned());
        let samples = [
            sample(at(28, 12), 40.0),
            sample(at(29, 12), 50.0),
            sample(at(30, 12), 60.0),
        ];
        for sample in &samples {
            log.append(sample).expect("append");
        }
        // A crash after the rename leaves both copies of the 28th.
        write_gzip(
            &log.day_file(at(28, 0).date_naive()),
            &dir.path().join("2026-10-28.jsonl.gz"),
        )
        .expect("gzip");

        let compressed = log
            .compress_finished(at(30, 0).date_naive())
            .expect("compress");
        assert_eq!(names(&compressed), ["2026-10-29.jsonl.gz"]);
        let mut files: Vec<_> = fs::read_dir(dir.path())
            .expect("list")
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .collect();
        files.sort();
        assert_eq!(
            files,
            [
                "2026-10-28.jsonl.gz",
                "2026-10-29.jsonl.gz",
                "2026-10-30.jsonl"
            ]
        );
        assert_eq!(log.since(at(1, 0)).expect("since"), samples);

        // Once today is finished too, the newest sample comes from a gzip.
        log.compress_finished(at(31, 0).date_naive())
            .expect("compress");
        assert_eq!(log.latest().expect("latest").as_ref(), Some(&samples[2]));
    }

    #[test]
    fn prune_keeps_the_newest_days_including_today() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = ThermalLog::new(dir.path().to_owned());
        for day in 25..=30 {
            log.append(&sample(at(day, 12), 50.0)).expect("append");
        }
        log.compress_finished(at(27, 0).date_naive())
            .expect("compress");
        fs::write(dir.path().join("notes.txt"), "keep").expect("write");

        let removed = log.prune(3, at(30, 0).date_naive()).expect("prune");
        assert_eq!(
            names(&removed),
            [
                "2026-10-25.jsonl.gz",
                "2026-10-26.jsonl.gz",
                "2026-10-27.jsonl"
            ]
        );
        assert_eq!(log.since(at(1, 0)).expect("since").len(), 3);
        assert!(dir.path().join("notes.txt").exists());
    }
}
