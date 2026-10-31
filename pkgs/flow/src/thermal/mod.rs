//! Temperature and fan readings from the BMC (IPMI) and the OS sensor
//! interface (Linux hwmon, macOS SMC/HID), judged against configured limits
//! and kept in an append-only daily log.

pub mod ipmi;
pub mod log;
pub mod notify;
mod os;

use chrono::{DateTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fmt;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Ipmi,
    Os,
}

impl fmt::Display for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ipmi => f.write_str("ipmi"),
            Self::Os => f.write_str("os"),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    TempC,
    FanRpm,
}

impl Kind {
    pub fn format_value(self, value: f64) -> String {
        match self {
            Self::TempC => format!("{value:.0}°C"),
            Self::FanRpm => format!("{value:.0} rpm"),
        }
    }
}

/// Sensor state as the BMC reports it. `Other` keeps codes this parser does
/// not know so they still raise an alert instead of passing as healthy.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BmcStatus {
    Ok,
    NonCritical,
    Critical,
    NonRecoverable,
    Other(String),
}

/// A reading as a source reports it, before limits are applied.
#[derive(Clone, Debug, PartialEq)]
pub struct RawReading {
    pub source: Source,
    pub sensor: String,
    pub kind: Kind,
    pub value: f64,
    pub bmc_status: Option<BmcStatus>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Reading {
    pub source: Source,
    pub sensor: String,
    pub kind: Kind,
    pub value: f64,
    /// Alert threshold in °C; temperatures only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bmc_status: Option<BmcStatus>,
    pub alert: bool,
}

impl Reading {
    fn key(&self) -> (Source, &str) {
        (self.source, &self.sensor)
    }

    /// Degrees below (negative) or above the limit.
    pub fn margin(&self) -> Option<f64> {
        self.limit.map(|limit| self.value - limit)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    pub at: DateTime<Utc>,
    pub readings: Vec<Reading>,
    /// Sources that could not be read; their sensors are missing from `readings`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

impl Sample {
    /// Readings alerting now that were not alerting in `previous`, so a
    /// sensor that stays hot notifies once rather than on every sample.
    pub fn new_alerts(&self, previous: Option<&Sample>) -> Vec<&Reading> {
        let before: HashSet<(Source, &str)> = previous
            .into_iter()
            .flat_map(|sample| &sample.readings)
            .filter(|reading| reading.alert)
            .map(Reading::key)
            .collect();
        self.readings
            .iter()
            .filter(|reading| reading.alert && !before.contains(&reading.key()))
            .collect()
    }
}

/// A per-sensor limit: sensors whose name contains `pattern`
/// (case-insensitive) alert at `celsius`.
#[derive(Clone, Debug, PartialEq)]
pub struct LimitOverride {
    pattern: String,
    celsius: f64,
}

impl FromStr for LimitOverride {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (pattern, celsius) = value
            .rsplit_once('=')
            .ok_or_else(|| format!("expected PATTERN=CELSIUS, got `{value}`"))?;
        if pattern.is_empty() {
            return Err(format!("empty sensor pattern in `{value}`"));
        }
        Ok(Self {
            pattern: pattern.to_lowercase(),
            celsius: parse_celsius(celsius)?,
        })
    }
}

pub fn parse_celsius(value: &str) -> Result<f64, String> {
    match value.trim().parse::<f64>() {
        Ok(celsius) if celsius.is_finite() => Ok(celsius),
        _ => Err(format!("expected a temperature in °C, got `{value}`")),
    }
}

/// Parses `90s`, `30m`, `2h`, or `7d`.
pub fn parse_duration(value: &str) -> Result<TimeDelta, String> {
    let invalid = || format!("expected a duration like 90s, 30m, 2h or 7d, got `{value}`");
    let split = value.len().checked_sub(1).ok_or_else(invalid)?;
    let (number, unit) = value.split_at_checked(split).ok_or_else(invalid)?;
    let number: i64 = number.parse().map_err(|_| invalid())?;
    let delta = match unit {
        "s" => TimeDelta::try_seconds(number),
        "m" => TimeDelta::try_minutes(number),
        "h" => TimeDelta::try_hours(number),
        "d" => TimeDelta::try_days(number),
        _ => None,
    };
    delta
        .filter(|delta| *delta > TimeDelta::zero())
        .ok_or_else(invalid)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Limits {
    default_c: f64,
    overrides: Vec<LimitOverride>,
}

impl Limits {
    pub fn new(default_c: f64, overrides: Vec<LimitOverride>) -> Self {
        Self {
            default_c,
            overrides,
        }
    }

    /// The first matching override wins; otherwise the default applies.
    pub fn limit_for(&self, sensor: &str) -> f64 {
        let sensor = sensor.to_lowercase();
        self.overrides
            .iter()
            .find(|limit| sensor.contains(&limit.pattern))
            .map_or(self.default_c, |limit| limit.celsius)
    }

    /// A reading alerts when the BMC flags it, or when a temperature reaches
    /// its limit.
    pub fn judge(&self, raw: RawReading) -> Reading {
        let bmc_alert = raw
            .bmc_status
            .as_ref()
            .is_some_and(|status| *status != BmcStatus::Ok);
        let limit = match raw.kind {
            Kind::TempC => Some(self.limit_for(&raw.sensor)),
            Kind::FanRpm => None,
        };
        Reading {
            alert: bmc_alert || limit.is_some_and(|limit| raw.value >= limit),
            source: raw.source,
            sensor: raw.sensor,
            kind: raw.kind,
            value: raw.value,
            limit,
            bmc_status: raw.bmc_status,
        }
    }
}

/// Reads every available source. A source that fails is recorded in
/// `errors` and the others are still read.
pub fn collect(limits: &Limits, at: DateTime<Utc>) -> Sample {
    let mut raw = Vec::new();
    let mut errors = Vec::new();
    for (name, result) in [("ipmi", ipmi::read()), ("os", os::read())] {
        match result {
            Ok(readings) => raw.extend(readings),
            Err(error) => errors.push(format!("{name}: {error:#}")),
        }
    }
    Sample {
        at,
        readings: raw
            .into_iter()
            .map(|reading| limits.judge(reading))
            .collect(),
        errors,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(sensor: &str, value: f64, bmc_status: Option<BmcStatus>) -> RawReading {
        RawReading {
            source: Source::Ipmi,
            sensor: sensor.to_owned(),
            kind: Kind::TempC,
            value,
            bmc_status,
        }
    }

    fn limits() -> Limits {
        Limits::new(
            90.0,
            vec![
                "vrmcpu=80".parse().expect("valid"),
                "VRM=85".parse().expect("valid"),
            ],
        )
    }

    #[test]
    fn first_matching_override_wins_over_later_overrides_and_default() {
        let limits = limits();
        assert_eq!(limits.limit_for("VRMCpu1 Temp"), 80.0);
        assert_eq!(limits.limit_for("VRMSoc1 Temp"), 85.0);
        assert_eq!(limits.limit_for("CPU1 Temp"), 90.0);
    }

    #[test]
    fn temperature_alerts_at_its_limit_not_below() {
        let limits = limits();
        assert!(!limits.judge(temp("VRMCpu1 Temp", 79.9, None)).alert);
        assert!(limits.judge(temp("VRMCpu1 Temp", 80.0, None)).alert);
    }

    #[test]
    fn bmc_flag_alerts_even_below_the_limit() {
        let limits = limits();
        let flagged = [
            BmcStatus::NonCritical,
            BmcStatus::Critical,
            BmcStatus::Other("lnc".to_owned()),
        ];
        for status in flagged {
            assert!(limits.judge(temp("System Temp", 30.0, Some(status))).alert);
        }
        assert!(
            !limits
                .judge(temp("System Temp", 30.0, Some(BmcStatus::Ok)))
                .alert
        );
    }

    #[test]
    fn fans_alert_only_when_the_bmc_flags_them() {
        let fan = |status| RawReading {
            source: Source::Ipmi,
            sensor: "FAN1".to_owned(),
            kind: Kind::FanRpm,
            value: 300.0,
            bmc_status: Some(status),
        };
        let limits = limits();
        assert!(!limits.judge(fan(BmcStatus::Ok)).alert);
        assert!(limits.judge(fan(BmcStatus::Critical)).alert);
    }

    #[test]
    fn a_sensor_notifies_once_while_it_stays_hot() {
        let limits = limits();
        let sample = |values: [f64; 2]| Sample {
            at: DateTime::UNIX_EPOCH,
            readings: vec![
                limits.judge(temp("VRMCpu1 Temp", values[0], None)),
                limits.judge(temp("VRMCpu2 Temp", values[1], None)),
            ],
            errors: Vec::new(),
        };
        let cool = sample([60.0, 60.0]);
        let one_hot = sample([81.0, 60.0]);
        let both_hot = sample([82.0, 81.0]);

        let names = |alerts: Vec<&Reading>| -> Vec<String> {
            alerts.into_iter().map(|r| r.sensor.clone()).collect()
        };
        assert_eq!(names(one_hot.new_alerts(None)), ["VRMCpu1 Temp"]);
        assert_eq!(names(one_hot.new_alerts(Some(&cool))), ["VRMCpu1 Temp"]);
        assert_eq!(names(both_hot.new_alerts(Some(&one_hot))), ["VRMCpu2 Temp"]);
        assert!(both_hot.new_alerts(Some(&both_hot)).is_empty());
    }

    #[test]
    fn rejects_malformed_limits_and_durations() {
        for bad in ["VRM", "=80", "VRM=hot", "VRM=inf"] {
            assert!(bad.parse::<LimitOverride>().is_err(), "{bad}");
        }
        assert_eq!(parse_duration("90s"), Ok(TimeDelta::seconds(90)));
        assert_eq!(parse_duration("2h"), Ok(TimeDelta::hours(2)));
        for bad in ["", "h", "10", "0m", "-5m", "5w", "1.5h", "5é"] {
            assert!(parse_duration(bad).is_err(), "{bad}");
        }
    }
}
