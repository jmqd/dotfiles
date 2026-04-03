use tracing::level_filters::LevelFilter;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

pub use tracing;

#[derive(Clone, Copy, Debug, Eq, PartialEq, clap::ValueEnum)]
pub enum LogFormat {
    Pretty,
    Json,
}

impl std::fmt::Display for LogFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pretty => f.write_str("pretty"),
            Self::Json => f.write_str("json"),
        }
    }
}

#[derive(Clone, Debug)]
pub struct LoggingOptions {
    pub automated: bool,
    pub format: Option<LogFormat>,
    pub default_level: LevelFilter,
}

impl Default for LoggingOptions {
    fn default() -> Self {
        #[cfg(debug_assertions)]
        let default_level = LevelFilter::INFO;
        #[cfg(not(debug_assertions))]
        let default_level = LevelFilter::WARN;

        Self {
            automated: false,
            format: None,
            default_level,
        }
    }
}

impl LoggingOptions {
    pub fn resolved_format(&self) -> LogFormat {
        self.format.unwrap_or(if self.automated {
            LogFormat::Json
        } else {
            LogFormat::Pretty
        })
    }
}

pub fn init(options: &LoggingOptions) {
    let env_filter = EnvFilter::builder()
        .with_default_directive(options.default_level.into())
        .from_env_lossy();

    match options.resolved_format() {
        LogFormat::Pretty => {
            tracing_subscriber::registry()
                .with(env_filter)
                .with(
                    fmt::layer()
                        .pretty()
                        .with_file(true)
                        .with_line_number(true)
                        .with_writer(std::io::stderr),
                )
                .init();
        }
        LogFormat::Json => {
            tracing_subscriber::registry()
                .with(env_filter)
                .with(
                    fmt::layer()
                        .json()
                        .with_file(true)
                        .with_line_number(true)
                        .with_current_span(true)
                        .with_span_list(true)
                        .with_writer(std::io::stderr),
                )
                .init();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{LogFormat, LoggingOptions};

    #[test]
    fn automated_logging_defaults_to_json() {
        let options = LoggingOptions {
            automated: true,
            format: None,
            ..Default::default()
        };
        assert_eq!(options.resolved_format(), LogFormat::Json);
    }

    #[test]
    fn explicit_log_format_overrides_default() {
        let options = LoggingOptions {
            automated: true,
            format: Some(LogFormat::Pretty),
            ..Default::default()
        };
        assert_eq!(options.resolved_format(), LogFormat::Pretty);
    }
}
