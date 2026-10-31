//! BMC sensors through `ipmitool sdr`. Boards without a BMC have no IPMI
//! device and contribute no readings.

use super::{BmcStatus, Kind, RawReading, Source};
use anyhow::{Context as _, bail};
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::path::Path;
use std::process::Command;

const DEVICES: [&str; 3] = ["/dev/ipmi0", "/dev/ipmi/0", "/dev/ipmidev/0"];
const SENSOR_TYPES: [&str; 2] = ["Temperature", "Fan"];

pub fn read() -> anyhow::Result<Vec<RawReading>> {
    let Some(device) = DEVICES
        .into_iter()
        .map(Path::new)
        .find(|path| path.exists())
    else {
        return Ok(Vec::new());
    };
    // Probe access first so a non-root caller gets a pointer to the logged
    // readings instead of ipmitool's generic open failure.
    if let Err(error) = OpenOptions::new().read(true).write(true).open(device) {
        if error.kind() == ErrorKind::PermissionDenied {
            bail!(
                "{} needs root; the flow-thermal service logs BMC sensors, see `flow thermal history`",
                device.display()
            );
        }
        return Err(error).with_context(|| format!("opening {}", device.display()));
    }

    let mut readings = Vec::new();
    for sensor_type in SENSOR_TYPES {
        readings.extend(parse_sdr(&ipmitool(&["sdr", "type", sensor_type])?));
    }
    Ok(readings)
}

fn ipmitool(args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new("ipmitool")
        .args(args)
        .output()
        .context("running ipmitool (is it installed?)")?;
    if !output.status.success() {
        bail!(
            "ipmitool {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    String::from_utf8(output.stdout).context("ipmitool printed non-UTF-8 output")
}

/// Parses `ipmitool sdr` rows such as
/// `VRMCpu1 Temp     | 10h | ok  |  8.1 | 72 degrees C`.
/// Rows without a reading (`ns`, `No Reading`) or in other units are skipped.
pub fn parse_sdr(text: &str) -> Vec<RawReading> {
    text.lines().filter_map(parse_row).collect()
}

fn parse_row(line: &str) -> Option<RawReading> {
    let fields: Vec<&str> = line.split('|').map(str::trim).collect();
    let [sensor, _id, status, _entity, reading] = fields.as_slice() else {
        return None;
    };
    let (value, kind) = if let Some(value) = reading.strip_suffix("degrees C") {
        (value, Kind::TempC)
    } else {
        (reading.strip_suffix("RPM")?, Kind::FanRpm)
    };
    let value: f64 = value.trim().parse().ok()?;
    let bmc_status = match *status {
        "ok" => BmcStatus::Ok,
        "nc" => BmcStatus::NonCritical,
        "cr" => BmcStatus::Critical,
        "nr" => BmcStatus::NonRecoverable,
        "ns" => return None,
        other => BmcStatus::Other(other.to_owned()),
    };
    Some(RawReading {
        source: Source::Ipmi,
        sensor: (*sensor).to_owned(),
        kind,
        value,
        bmc_status: Some(bmc_status),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Rows from jmws's `ipmitool sdr` output; VRMCpu1 is raised to a `cr`
    // reading and FAN5 made absent to cover those cases.
    const TEMPERATURES: &str = "\
CPU1 Temp        | 01h | ok  |  3.1 | 54 degrees C
System Temp      | 0Bh | ok  |  7.1 | 28 degrees C
MB_10G Temp      | 0Dh | ns  |  7.4 | No Reading
VRMCpu1 Temp     | 10h | cr  |  8.1 | 106 degrees C
P1_DIMMA~D Temp  | B0h | ok  | 32.64 | 43 degrees C
";
    const FANS: &str = "\
FAN1             | 41h | ok  | 29.1 | 2100 RPM
FAN5             | 45h | ns  | 29.5 | No Reading
";

    #[test]
    fn parses_temperatures_and_fans_and_skips_absent_sensors() {
        let readings: Vec<_> = parse_sdr(TEMPERATURES)
            .into_iter()
            .chain(parse_sdr(FANS))
            .map(|r| (r.sensor, r.kind, r.value, r.bmc_status))
            .collect();
        assert_eq!(
            readings,
            [
                (
                    "CPU1 Temp".to_owned(),
                    Kind::TempC,
                    54.0,
                    Some(BmcStatus::Ok)
                ),
                (
                    "System Temp".to_owned(),
                    Kind::TempC,
                    28.0,
                    Some(BmcStatus::Ok)
                ),
                (
                    "VRMCpu1 Temp".to_owned(),
                    Kind::TempC,
                    106.0,
                    Some(BmcStatus::Critical)
                ),
                (
                    "P1_DIMMA~D Temp".to_owned(),
                    Kind::TempC,
                    43.0,
                    Some(BmcStatus::Ok)
                ),
                ("FAN1".to_owned(), Kind::FanRpm, 2100.0, Some(BmcStatus::Ok)),
            ]
        );
    }
}
