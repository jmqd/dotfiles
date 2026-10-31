use crate::cli::{
    ThermalArgs, ThermalBarArgs, ThermalCommands, ThermalHistoryArgs, ThermalLimitArgs,
    ThermalLogArgs, ThermalSampleArgs,
};
use crate::context::Ctx;
use crate::logging::tracing;
use crate::thermal::log::{ThermalLog, default_dir};
use crate::thermal::{self, Kind, Limits, Reading, Sample, Source, notify};
use anyhow::{Context as _, bail};
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(untagged)]
pub enum ThermalOutput {
    Read(Sample),
    Sample(SampleOutput),
    History(History),
    Bar(BarBlock),
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SampleOutput {
    pub log_file: PathBuf,
    pub sample: Sample,
    pub new_alerts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct History {
    pub log_dir: PathBuf,
    pub since: DateTime<Utc>,
    pub samples: usize,
    pub latest_at: Option<DateTime<Utc>>,
    pub sensors: Vec<SensorHistory>,
    /// Source errors in the newest sample.
    pub errors: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SensorHistory {
    pub source: Source,
    pub sensor: String,
    pub kind: Kind,
    pub latest: f64,
    pub min: f64,
    pub max: f64,
    pub max_at: DateTime<Utc>,
    pub limit: Option<f64>,
    /// Samples in the window where this sensor alerted.
    pub alerts: usize,
}

/// An i3status-rust `custom` block with `json = true`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BarBlock {
    pub text: String,
    pub state: BarState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum BarState {
    Idle,
    Warning,
    Critical,
}

/// The bar warns this many °C before a temperature reaches its limit.
const BAR_WARNING_MARGIN_C: f64 = 10.0;

pub fn execute(_ctx: &Ctx, args: ThermalArgs) -> anyhow::Result<ThermalOutput> {
    match args.command {
        ThermalCommands::Read(args) => Ok(ThermalOutput::Read(thermal::collect(
            &limits(args.limits),
            Utc::now(),
        ))),
        ThermalCommands::Sample(args) => sample(args).map(ThermalOutput::Sample),
        ThermalCommands::History(args) => history(args).map(ThermalOutput::History),
        ThermalCommands::Bar(args) => bar(args).map(ThermalOutput::Bar),
    }
}

fn limits(args: ThermalLimitArgs) -> Limits {
    Limits::new(args.alert_at, args.limits)
}

fn open_log(args: ThermalLogArgs) -> anyhow::Result<ThermalLog> {
    let dir = args
        .log_dir
        .or_else(default_dir)
        .context("no default log directory on this platform; pass --log-dir")?;
    Ok(ThermalLog::new(dir))
}

fn sample(args: ThermalSampleArgs) -> anyhow::Result<SampleOutput> {
    let log = open_log(args.log)?;
    let previous = log.latest()?;
    let sample = thermal::collect(&limits(args.limits), Utc::now());
    let log_file = log.append(&sample)?;

    let new_alerts: Vec<String> = sample
        .new_alerts(previous.as_ref())
        .into_iter()
        .map(describe)
        .collect();
    for alert in &new_alerts {
        tracing::warn!(alert = %alert, "thermal alert");
    }
    for error in &sample.errors {
        tracing::warn!(error = %error, "sensor source unavailable");
    }
    if args.notify && !new_alerts.is_empty() {
        // A failed notification must not lose the sample already logged.
        if let Err(error) = notify::desktop("Thermal alert", &new_alerts.join("\n")) {
            tracing::warn!(error = %format!("{error:#}"), "desktop notification failed");
        }
    }
    match log.prune(args.keep_days, sample.at.date_naive()) {
        Ok(removed) => {
            for path in removed {
                tracing::info!(path = %path.display(), "removed old thermal log");
            }
        }
        Err(error) => tracing::warn!(error = %format!("{error:#}"), "pruning thermal logs failed"),
    }

    if sample.readings.is_empty() {
        bail!(
            "no sensors could be read ({})",
            if sample.errors.is_empty() {
                "none found".to_owned()
            } else {
                sample.errors.join("; ")
            }
        );
    }
    Ok(SampleOutput {
        log_file,
        sample,
        new_alerts,
    })
}

fn history(args: ThermalHistoryArgs) -> anyhow::Result<History> {
    let log = open_log(args.log)?;
    let since = Utc::now() - args.since;
    let samples = log.since(since)?;

    let mut sensors: Vec<SensorHistory> = Vec::new();
    let mut index: HashMap<(Source, String), usize> = HashMap::new();
    for sample in &samples {
        for reading in &sample.readings {
            let key = (reading.source, reading.sensor.clone());
            let Some(&slot) = index.get(&key) else {
                index.insert(key, sensors.len());
                sensors.push(SensorHistory {
                    source: reading.source,
                    sensor: reading.sensor.clone(),
                    kind: reading.kind,
                    latest: reading.value,
                    min: reading.value,
                    max: reading.value,
                    max_at: sample.at,
                    limit: reading.limit,
                    alerts: usize::from(reading.alert),
                });
                continue;
            };
            let entry = &mut sensors[slot];
            entry.latest = reading.value;
            entry.limit = reading.limit;
            entry.min = entry.min.min(reading.value);
            if reading.value >= entry.max {
                entry.max = reading.value;
                entry.max_at = sample.at;
            }
            entry.alerts += usize::from(reading.alert);
        }
    }

    Ok(History {
        log_dir: log.dir().to_owned(),
        since,
        samples: samples.len(),
        latest_at: samples.last().map(|sample| sample.at),
        errors: samples
            .last()
            .map(|sample| sample.errors.clone())
            .unwrap_or_default(),
        sensors,
    })
}

fn bar(args: ThermalBarArgs) -> anyhow::Result<BarBlock> {
    let log = open_log(args.log)?;
    Ok(match log.latest()? {
        // No sampler on this machine: an empty text hides the block.
        None => BarBlock {
            text: String::new(),
            state: BarState::Idle,
        },
        Some(sample) if Utc::now() - sample.at > args.stale_after => BarBlock {
            text: "thermal: stale".to_owned(),
            state: BarState::Warning,
        },
        Some(sample) => bar_block(&sample),
    })
}

/// Shows the reading closest to (or furthest past) its limit, or the first
/// flagged fan when only fans alert.
fn bar_block(sample: &Sample) -> BarBlock {
    let hottest = sample
        .readings
        .iter()
        .filter_map(|reading| Some((reading, reading.margin()?)))
        .max_by(|(_, a), (_, b)| a.total_cmp(b));
    let flagged = sample.readings.iter().find(|reading| reading.alert);
    let (reading, state) = match (hottest, flagged) {
        (Some((reading, _)), _) if reading.alert => (reading, BarState::Critical),
        (_, Some(reading)) => (reading, BarState::Critical),
        (Some((reading, margin)), None) if margin >= -BAR_WARNING_MARGIN_C => {
            (reading, BarState::Warning)
        }
        (Some((reading, _)), None) => (reading, BarState::Idle),
        (None, None) => {
            return BarBlock {
                text: String::new(),
                state: BarState::Idle,
            };
        }
    };
    BarBlock {
        text: format!(
            "{} {}",
            reading.sensor,
            reading.kind.format_value(reading.value)
        ),
        state,
    }
}

fn describe(reading: &Reading) -> String {
    let value = reading.kind.format_value(reading.value);
    match (reading.limit, &reading.bmc_status) {
        (Some(limit), _) if reading.value >= limit => {
            format!("{} at {value} (limit {limit:.0}°C)", reading.sensor)
        }
        (_, Some(status)) => format!("{} at {value} (BMC status {status:?})", reading.sensor),
        _ => format!("{} at {value}", reading.sensor),
    }
}

pub fn format_text(output: &ThermalOutput) -> String {
    match output {
        ThermalOutput::Read(sample) => format_sample(sample).join("\n"),
        ThermalOutput::Sample(output) => {
            let mut lines = vec![format!("logged to {}", output.log_file.display())];
            lines.extend(
                output
                    .new_alerts
                    .iter()
                    .map(|alert| format!("new alert: {alert}")),
            );
            lines.extend(format_sample(&output.sample));
            lines.join("\n")
        }
        ThermalOutput::History(history) => format_history(history).join("\n"),
        // i3status-rust parses the line itself, so text output is the JSON.
        ThermalOutput::Bar(block) => {
            serde_json::to_string(block).expect("BarBlock serializes to JSON")
        }
    }
}

fn format_sample(sample: &Sample) -> Vec<String> {
    let width = sample
        .readings
        .iter()
        .map(|reading| reading.sensor.chars().count())
        .max()
        .unwrap_or(0);
    let mut lines: Vec<String> = sample
        .readings
        .iter()
        .map(|reading| {
            let limit = reading
                .limit
                .map(|limit| format!("limit {limit:.0}°C"))
                .unwrap_or_default();
            format!(
                "{:<4}  {:<width$}  {:>8}  {:<13} {}",
                reading.source.to_string(),
                reading.sensor,
                reading.kind.format_value(reading.value),
                limit,
                if reading.alert { "ALERT" } else { "ok" },
            )
        })
        .collect();
    lines.extend(
        sample
            .errors
            .iter()
            .map(|error| format!("unavailable: {error}")),
    );
    lines
}

fn format_history(history: &History) -> Vec<String> {
    let summary = format!(
        "{} samples since {} from {}",
        history.samples,
        history.since.format("%Y-%m-%d %H:%M UTC"),
        history.log_dir.display(),
    );
    let Some(latest_at) = history.latest_at else {
        return vec![
            summary,
            "no samples in this window; is the flow-thermal sampler running?".to_owned(),
        ];
    };
    let width = history
        .sensors
        .iter()
        .map(|sensor| sensor.sensor.chars().count())
        .max()
        .unwrap_or(0);
    let mut lines = vec![
        format!("{summary}, newest {}", latest_at.format("%H:%M:%S UTC")),
        format!(
            "{:<4}  {:<width$}  {:>8}  {:>8}  {:>8}  {:<9}  {:>6}  ALERTS",
            "SRC", "SENSOR", "NOW", "MIN", "MAX", "MAX AT", "LIMIT",
        ),
    ];
    lines.extend(history.sensors.iter().map(|sensor| {
        let limit = sensor
            .limit
            .map(|limit| format!("{limit:.0}°C"))
            .unwrap_or_default();
        format!(
            "{:<4}  {:<width$}  {:>8}  {:>8}  {:>8}  {:<9}  {:>6}  {}",
            sensor.source.to_string(),
            sensor.sensor,
            sensor.kind.format_value(sensor.latest),
            sensor.kind.format_value(sensor.min),
            sensor.kind.format_value(sensor.max),
            sensor.max_at.format("%H:%M:%S"),
            limit,
            sensor.alerts,
        )
    }));
    lines.extend(
        history
            .errors
            .iter()
            .map(|error| format!("unavailable: {error}")),
    );
    lines
}
