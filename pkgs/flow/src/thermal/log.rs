//! Append-only sample log: one JSON line per sample in `<dir>/<UTC date>.jsonl`.

use super::Sample;
use anyhow::Context as _;
use chrono::{DateTime, Days, NaiveDate, Utc};
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read as _, Seek as _, SeekFrom, Write as _};
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
        for (_, path) in self.days()?.into_iter().rev() {
            if let Some(sample) = last_sample(&path)? {
                return Ok(Some(sample));
            }
        }
        Ok(None)
    }

    /// Samples taken at or after `start`, oldest first.
    pub fn since(&self, start: DateTime<Utc>) -> anyhow::Result<Vec<Sample>> {
        let mut samples = Vec::new();
        for (day, path) in self.days()? {
            if day < start.date_naive() {
                continue;
            }
            let text =
                fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
            samples.extend(
                text.lines()
                    .filter_map(|line| serde_json::from_str::<Sample>(line).ok())
                    .filter(|sample| sample.at >= start),
            );
        }
        Ok(samples)
    }

    /// Deletes day files older than the newest `keep_days` days ending at
    /// `today`, and returns them.
    pub fn prune(&self, keep_days: u32, today: NaiveDate) -> anyhow::Result<Vec<PathBuf>> {
        let Some(oldest_kept) = today.checked_sub_days(Days::new(u64::from(keep_days.max(1)) - 1))
        else {
            return Ok(Vec::new());
        };
        let mut removed = Vec::new();
        for (day, path) in self.days()? {
            if day < oldest_kept {
                fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))?;
                removed.push(path);
            }
        }
        Ok(removed)
    }

    fn day_file(&self, day: NaiveDate) -> PathBuf {
        self.dir.join(format!("{day}.jsonl"))
    }

    /// Day files sorted oldest first; a missing directory has none.
    fn days(&self) -> anyhow::Result<Vec<(NaiveDate, PathBuf)>> {
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(error).with_context(|| format!("listing {}", self.dir.display()));
            }
        };
        let mut days = Vec::new();
        for entry in entries {
            let path = entry?.path();
            let day = path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".jsonl"))
                .and_then(|stem| stem.parse::<NaiveDate>().ok());
            if let Some(day) = day {
                days.push((day, path));
            }
        }
        days.sort();
        Ok(days)
    }
}

fn last_sample(path: &Path) -> anyhow::Result<Option<Sample>> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    let mut tail = Vec::new();
    file.seek(SeekFrom::Start(start))?;
    file.read_to_end(&mut tail)?;
    if let Some(sample) = newest_parsable(&tail) {
        return Ok(Some(sample));
    }
    if start == 0 {
        return Ok(None);
    }
    // A line longer than the tail window; fall back to the whole file.
    let whole = fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    Ok(newest_parsable(&whole))
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
    fn prune_keeps_the_newest_days_including_today() {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = ThermalLog::new(dir.path().to_owned());
        for day in 25..=30 {
            log.append(&sample(at(day, 12), 50.0)).expect("append");
        }
        fs::write(dir.path().join("notes.txt"), "keep").expect("write");

        let removed = log.prune(3, at(30, 0).date_naive()).expect("prune");
        let removed: Vec<_> = removed
            .iter()
            .filter_map(|path| path.file_name()?.to_str())
            .collect();
        assert_eq!(
            removed,
            ["2026-10-25.jsonl", "2026-10-26.jsonl", "2026-10-27.jsonl"]
        );
        assert_eq!(log.since(at(1, 0)).expect("since").len(), 3);
        assert!(dir.path().join("notes.txt").exists());
    }
}
