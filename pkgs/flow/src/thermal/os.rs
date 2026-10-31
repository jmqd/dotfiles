//! Temperatures the OS exposes without privileges: hwmon on Linux, SMC and
//! HID sensors on macOS.

use super::{Kind, RawReading, Source};
use std::collections::HashMap;

#[cfg(target_os = "linux")]
pub fn read() -> anyhow::Result<Vec<RawReading>> {
    hwmon::read(std::path::Path::new("/sys/class/hwmon"))
}

#[cfg(target_os = "macos")]
pub fn read() -> anyhow::Result<Vec<RawReading>> {
    let components = sysinfo::Components::new_with_refreshed_list()
        .map_err(|error| anyhow::anyhow!("listing sensors: {error}"))?;
    let mut sensors: Vec<(String, f64)> = components
        .iter()
        .filter_map(|component| {
            Some((
                component.label().to_owned(),
                f64::from(component.temperature()?),
            ))
        })
        .collect();
    sensors.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(readings(sensors))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read() -> anyhow::Result<Vec<RawReading>> {
    anyhow::bail!("reading OS sensors is not supported on this platform")
}

/// Drops sensors that are present but idle (no value, or 0), and numbers
/// repeated names (`#2`, `#3`) so each sensor keeps a distinct key.
fn readings(sensors: Vec<(String, f64)>) -> Vec<RawReading> {
    let mut seen: HashMap<String, usize> = HashMap::new();
    sensors
        .into_iter()
        .filter(|(_, celsius)| celsius.is_finite() && *celsius > 0.0)
        .map(|(name, celsius)| {
            let count = seen.entry(name.clone()).or_default();
            *count += 1;
            let sensor = if *count == 1 {
                name
            } else {
                format!("{name} #{count}")
            };
            RawReading {
                source: Source::Os,
                sensor,
                kind: Kind::TempC,
                value: celsius,
                bmc_status: None,
            }
        })
        .collect()
}

#[cfg(any(target_os = "linux", test))]
mod hwmon {
    use super::readings;
    use crate::thermal::RawReading;
    use anyhow::Context as _;
    use std::fs;
    use std::path::{Path, PathBuf};

    /// Reads every `tempN_input` under `root` (`/sys/class/hwmon`). Chips are
    /// ordered by their device path, which is stable across boots where the
    /// `hwmonN` numbering is not, so a second socket's `k10temp Tctl` is
    /// always the `#2`.
    pub fn read(root: &Path) -> anyhow::Result<Vec<RawReading>> {
        let mut chips: Vec<(PathBuf, PathBuf)> = Vec::new();
        for entry in fs::read_dir(root).with_context(|| format!("listing {}", root.display()))? {
            let dir = entry?.path();
            let order = fs::canonicalize(dir.join("device")).unwrap_or_else(|_| dir.clone());
            chips.push((order, dir));
        }
        chips.sort();

        let mut sensors = Vec::new();
        for (_, dir) in chips {
            let Some(chip) = read_line(&dir.join("name")) else {
                continue;
            };
            for channel in channels(&dir)? {
                // Some channels fail to read while their device sleeps.
                let Some(millidegrees) = read_line(&dir.join(format!("temp{channel}_input")))
                    .and_then(|text| text.parse::<i64>().ok())
                else {
                    continue;
                };
                let label = read_line(&dir.join(format!("temp{channel}_label")))
                    .unwrap_or_else(|| format!("temp{channel}"));
                sensors.push((format!("{chip} {label}"), millidegrees as f64 / 1000.0));
            }
        }
        Ok(readings(sensors))
    }

    /// Channel numbers N with a `tempN_input`, ascending.
    fn channels(dir: &Path) -> anyhow::Result<Vec<u32>> {
        let mut channels = Vec::new();
        for entry in fs::read_dir(dir).with_context(|| format!("listing {}", dir.display()))? {
            let name = entry?.file_name();
            let channel = name
                .to_str()
                .and_then(|name| name.strip_prefix("temp"))
                .and_then(|rest| rest.strip_suffix("_input"))
                .and_then(|number| number.parse::<u32>().ok());
            channels.extend(channel);
        }
        channels.sort_unstable();
        Ok(channels)
    }

    fn read_line(path: &Path) -> Option<String> {
        let text = fs::read_to_string(path).ok()?;
        let line = text.trim();
        (!line.is_empty()).then(|| line.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::hwmon;
    use std::fs;
    use std::path::Path;

    fn chip(
        root: &Path,
        hwmon: &str,
        device: &str,
        name: &str,
        channels: &[(u32, Option<&str>, &str)],
    ) {
        let devices = root.join("devices").join(device);
        fs::create_dir_all(&devices).expect("device dir");
        let dir = root.join("hwmon").join(hwmon);
        fs::create_dir_all(&dir).expect("hwmon dir");
        std::os::unix::fs::symlink(&devices, dir.join("device")).expect("device link");
        fs::write(dir.join("name"), format!("{name}\n")).expect("name");
        for (channel, label, input) in channels {
            fs::write(dir.join(format!("temp{channel}_input")), input).expect("input");
            if let Some(label) = label {
                fs::write(dir.join(format!("temp{channel}_label")), label).expect("label");
            }
        }
    }

    #[test]
    fn keeps_every_socket_and_orders_chips_by_device_path() {
        let root = tempfile::tempdir().expect("tempdir");
        let root = root.path();
        // hwmon numbering is reversed relative to the device order.
        chip(
            root,
            "hwmon2",
            "0000:00:18.3",
            "k10temp",
            &[(1, Some("Tctl"), "42750\n")],
        );
        chip(
            root,
            "hwmon1",
            "0000:00:19.3",
            "k10temp",
            &[(1, Some("Tctl"), "39250\n"), (3, Some("Tccd1"), "38000\n")],
        );
        chip(
            root,
            "hwmon0",
            "nvme0",
            "nvme",
            &[
                (1, None, "27850\n"),
                (2, Some("Sensor 1"), "0\n"),
                (3, Some("Sensor 2"), ""),
            ],
        );

        let readings: Vec<_> = hwmon::read(&root.join("hwmon"))
            .expect("read")
            .into_iter()
            .map(|reading| (reading.sensor, reading.value))
            .collect();
        assert_eq!(
            readings,
            [
                ("k10temp Tctl".to_owned(), 42.75),
                ("k10temp Tctl #2".to_owned(), 39.25),
                ("k10temp Tccd1".to_owned(), 38.0),
                ("nvme temp1".to_owned(), 27.85),
            ]
        );
    }
}
