use crate::logging::LogFormat;
use crate::output::OutputMode;
use clap::{Args, Parser, Subcommand};

#[derive(Args, Clone, Debug)]
pub struct GenerateCompletionsArgs {
    /// The shell to generate completions for.
    #[arg(long)]
    pub shell: clap_complete::Shell,
}

#[derive(Args, Clone, Debug, Default)]
pub struct DoctorArgs {}

#[derive(Args, Clone, Debug)]
pub struct CommonArgs {
    /// Enable automation-safe behavior (no prompts, stable output/logging defaults).
    #[arg(global = true, long, default_value_t = false)]
    pub automated: bool,

    /// Format for the command result written to stdout.
    #[arg(global = true, long, value_enum, default_value_t = OutputMode::Text)]
    pub output: OutputMode,

    /// Format for tracing logs written to stderr.
    #[arg(global = true, long, value_enum)]
    pub log_format: Option<LogFormat>,
}

#[derive(Parser, Clone, Debug)]
#[command(
    name = "flow",
    about = "jm.dev personal CLI",
    version,
    disable_help_subcommand = true,
    arg_required_else_help = true
)]
pub struct Cli {
    #[command(flatten)]
    pub common: CommonArgs,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Clone, Debug)]
pub enum Commands {
    /// Report basic runtime and configuration information for troubleshooting.
    Doctor(DoctorArgs),
    /// Generate shell completions.
    GenerateCompletions(GenerateCompletionsArgs),
}

impl Commands {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Doctor(_) => "doctor",
            Self::GenerateCompletions(_) => "generate-completions",
        }
    }
}

pub fn render_help_text(command: &mut clap::Command) -> anyhow::Result<String> {
    let mut buffer = Vec::new();
    command.write_long_help(&mut buffer)?;
    Ok(String::from_utf8(buffer)?)
}

#[cfg(test)]
mod tests {
    use super::{Cli, Commands, CommonArgs, DoctorArgs, GenerateCompletionsArgs, render_help_text};
    use crate::output::OutputMode;
    use clap::CommandFactory;
    use clap::Parser;

    #[test]
    fn clap_schema_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn parses_automated_json_doctor() {
        let cli = Cli::try_parse_from(["flow", "--automated", "--output", "json", "doctor"])
            .expect("parse succeeds");

        assert!(cli.common.automated);
        assert_eq!(cli.common.output, OutputMode::Json);
        assert!(matches!(cli.command, Commands::Doctor(_)));
    }

    #[test]
    fn renders_help_text_for_top_level_cli() {
        let help_text = render_help_text(&mut Cli::command()).expect("help text renders");
        assert!(help_text.contains("Usage: flow"));
        assert!(help_text.contains("doctor"));
        assert!(help_text.contains("generate-completions"));
    }

    #[test]
    fn command_name_matches_expected() {
        assert_eq!(Commands::Doctor(DoctorArgs::default()).name(), "doctor");
        assert_eq!(
            Commands::GenerateCompletions(GenerateCompletionsArgs {
                shell: clap_complete::Shell::Bash,
            })
            .name(),
            "generate-completions"
        );
    }

    #[test]
    fn constructs_common_args() {
        let args = CommonArgs {
            automated: true,
            output: OutputMode::Json,
            log_format: None,
        };
        assert!(args.automated);
    }
}
