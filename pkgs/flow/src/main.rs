use clap::{CommandFactory, Parser, error::ErrorKind};
use flow::cli::{Cli, Commands};
use flow::commands::doctor;
use flow::context::Ctx;
use flow::logging::{self, LoggingOptions, tracing};
use flow::output::{OutputMode, write_json, write_text};
use std::io;

fn main() -> anyhow::Result<()> {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let _ = error.print();
            match error.kind() {
                ErrorKind::DisplayHelp
                | ErrorKind::DisplayVersion
                | ErrorKind::MissingSubcommand
                | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => return Ok(()),
                _ => std::process::exit(error.exit_code()),
            }
        }
    };

    let Cli { common, command } = cli;
    let ctx = Ctx::new(common)?;

    logging::init(&LoggingOptions {
        automated: ctx.is_automated(),
        format: ctx.log_format(),
        ..Default::default()
    });

    let command_name = command.name();
    let invocation_span = tracing::info_span!(
        "flow.invocation",
        command = command_name,
        automated = ctx.is_automated(),
        output_mode = %ctx.output_mode(),
    );
    let _guard = invocation_span.enter();

    tracing::debug!(working_dir = %ctx.working_dir().display(), "dispatching command");

    match command {
        Commands::Doctor(args) => {
            let output = doctor::execute(&ctx, args)?;
            let stdout = io::stdout();
            let mut stdout = stdout.lock();
            match ctx.output_mode() {
                OutputMode::Text => write_text(&mut stdout, &doctor::format_text(&output))?,
                OutputMode::Json => write_json(&mut stdout, &output)?,
            }
        }
        Commands::GenerateCompletions(args) => {
            let bin_name = Cli::command().get_name().to_owned();
            clap_complete::generate(args.shell, &mut Cli::command(), bin_name, &mut io::stdout());
        }
    }

    Ok(())
}
