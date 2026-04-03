use clap::ValueEnum;
use serde::Serialize;
use std::fmt;
use std::io::Write;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum OutputMode {
    #[default]
    Text,
    Json,
}

impl fmt::Display for OutputMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text => f.write_str("text"),
            Self::Json => f.write_str("json"),
        }
    }
}

pub fn write_text(mut writer: impl Write, text: &str) -> anyhow::Result<()> {
    writer.write_all(text.as_bytes())?;
    writer.write_all(b"\n")?;
    Ok(())
}

pub fn write_json<T: Serialize>(mut writer: impl Write, value: &T) -> anyhow::Result<()> {
    serde_json::to_writer(&mut writer, value)?;
    writer.write_all(b"\n")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{OutputMode, write_json, write_text};

    #[test]
    fn output_mode_strings_are_stable() {
        assert_eq!(OutputMode::Text.to_string(), "text");
        assert_eq!(OutputMode::Json.to_string(), "json");
    }

    #[test]
    fn text_writer_appends_newline() {
        let mut buf = Vec::new();
        write_text(&mut buf, "hello").expect("write text succeeds");
        assert_eq!(String::from_utf8(buf).expect("valid utf8"), "hello\n");
    }

    #[test]
    fn json_writer_appends_newline() {
        let mut buf = Vec::new();
        write_json(&mut buf, &serde_json::json!({ "ok": true })).expect("write json succeeds");
        assert_eq!(
            String::from_utf8(buf).expect("valid utf8"),
            "{\"ok\":true}\n"
        );
    }
}
