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

#[derive(Args, Clone, Debug, Default)]
pub struct SearchReindexArgs {}

#[derive(Args, Clone, Debug, Default)]
pub struct SearchStatusArgs {}

#[derive(Args, Clone, Debug)]
pub struct SearchScopeArgs {
    /// Limit search to a specific repo name or path.
    #[arg(long)]
    pub repo: Option<String>,

    /// Narrow matches to paths containing this fragment.
    #[arg(long)]
    pub path: Option<String>,

    /// Maximum number of results returned per search domain.
    #[arg(long, default_value_t = 25)]
    pub limit: usize,
}

#[derive(Args, Clone, Debug)]
pub struct SearchQueryArgs {
    #[command(flatten)]
    pub scope: SearchScopeArgs,

    /// Filter commit results by author name or email.
    #[arg(long)]
    pub author: Option<String>,

    /// Filter commit results to those authored on or after this date/time.
    #[arg(long)]
    pub since: Option<String>,

    /// Include live matches from the current repo or the selected repo.
    #[arg(long, default_value_t = false)]
    pub include_dirty: bool,

    /// Skip Zoekt-backed code and path search.
    #[arg(long, default_value_t = false)]
    pub no_code: bool,

    /// Skip git metadata search.
    #[arg(long, default_value_t = false)]
    pub no_commits: bool,

    /// Terms to search for.
    #[arg(required = true)]
    pub terms: Vec<String>,
}

#[derive(Args, Clone, Debug)]
pub struct SearchCodeArgs {
    #[command(flatten)]
    pub scope: SearchScopeArgs,

    /// Terms to search for.
    #[arg(required = true)]
    pub terms: Vec<String>,
}

#[derive(Args, Clone, Debug)]
pub struct SearchCommitsArgs {
    #[command(flatten)]
    pub scope: SearchScopeArgs,

    /// Filter commit results by author name or email.
    #[arg(long)]
    pub author: Option<String>,

    /// Filter commit results to those authored on or after this date/time.
    #[arg(long)]
    pub since: Option<String>,

    /// Terms to search for.
    #[arg(required = true)]
    pub terms: Vec<String>,
}

#[derive(Subcommand, Clone, Debug)]
pub enum SearchCommands {
    /// Search across code, paths, commit metadata, and optional dirty state.
    Query(SearchQueryArgs),
    /// Search indexed code and paths.
    Code(SearchCodeArgs),
    /// Search indexed commit metadata.
    Commits(SearchCommitsArgs),
    /// Rebuild local code and metadata search indexes.
    Reindex(SearchReindexArgs),
    /// Report search configuration and index status information.
    Status(SearchStatusArgs),
}

#[derive(Args, Clone, Debug)]
pub struct SearchArgs {
    #[command(subcommand)]
    pub command: SearchCommands,
}

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
    /// Search local repositories, indexes, and git metadata.
    Search(SearchArgs),
    /// Generate shell completions.
    GenerateCompletions(GenerateCompletionsArgs),
}

impl Commands {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Doctor(_) => "doctor",
            Self::Search(_) => "search",
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
    use super::{
        Cli, Commands, CommonArgs, DoctorArgs, GenerateCompletionsArgs, SearchArgs, SearchCodeArgs,
        SearchCommands, SearchCommitsArgs, SearchQueryArgs, SearchReindexArgs, SearchScopeArgs,
        SearchStatusArgs, render_help_text,
    };
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
    fn parses_search_query_with_filters() {
        let cli = Cli::try_parse_from([
            "flow",
            "search",
            "query",
            "--repo",
            "dotfiles",
            "--include-dirty",
            "--since",
            "2026-04-01",
            "review",
            "scope",
        ])
        .expect("parse succeeds");

        match cli.command {
            Commands::Search(SearchArgs {
                command:
                    SearchCommands::Query(SearchQueryArgs {
                        scope,
                        include_dirty,
                        since,
                        terms,
                        ..
                    }),
            }) => {
                assert_eq!(scope.repo.as_deref(), Some("dotfiles"));
                assert!(include_dirty);
                assert_eq!(since.as_deref(), Some("2026-04-01"));
                assert_eq!(terms, vec!["review", "scope"]);
            }
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn parses_search_code_subcommand() {
        let cli = Cli::try_parse_from(["flow", "search", "code", "--path", "src", "review"])
            .expect("parse succeeds");

        match cli.command {
            Commands::Search(SearchArgs {
                command:
                    SearchCommands::Code(SearchCodeArgs {
                        scope,
                        terms,
                    }),
            }) => {
                assert_eq!(scope.path.as_deref(), Some("src"));
                assert_eq!(terms, vec!["review"]);
            }
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn parses_search_commits_subcommand() {
        let cli = Cli::try_parse_from([
            "flow",
            "search",
            "commits",
            "--author",
            "jmq",
            "--since",
            "2026-04-01",
            "review",
        ])
        .expect("parse succeeds");

        match cli.command {
            Commands::Search(SearchArgs {
                command:
                    SearchCommands::Commits(SearchCommitsArgs {
                        author,
                        since,
                        terms,
                        ..
                    }),
            }) => {
                assert_eq!(author.as_deref(), Some("jmq"));
                assert_eq!(since.as_deref(), Some("2026-04-01"));
                assert_eq!(terms, vec!["review"]);
            }
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn parses_search_reindex_subcommand() {
        let cli = Cli::try_parse_from(["flow", "search", "reindex"]).expect("parse succeeds");
        assert!(matches!(
            cli.command,
            Commands::Search(SearchArgs {
                command: SearchCommands::Reindex(SearchReindexArgs {})
            })
        ));
    }

    #[test]
    fn parses_search_status_subcommand() {
        let cli = Cli::try_parse_from(["flow", "search", "status"]).expect("parse succeeds");
        assert!(matches!(
            cli.command,
            Commands::Search(SearchArgs {
                command: SearchCommands::Status(SearchStatusArgs {})
            })
        ));
    }

    #[test]
    fn renders_help_text_for_top_level_cli() {
        let help_text = render_help_text(&mut Cli::command()).expect("help text renders");
        assert!(help_text.contains("Usage: flow"));
        assert!(help_text.contains("doctor"));
        assert!(help_text.contains("search"));
        assert!(help_text.contains("generate-completions"));
    }

    #[test]
    fn command_name_matches_expected() {
        assert_eq!(Commands::Doctor(DoctorArgs::default()).name(), "doctor");
        assert_eq!(
            Commands::Search(SearchArgs {
                command: SearchCommands::Query(SearchQueryArgs {
                    scope: SearchScopeArgs {
                        repo: None,
                        path: None,
                        limit: 25,
                    },
                    author: None,
                    since: None,
                    include_dirty: false,
                    no_code: false,
                    no_commits: false,
                    terms: vec!["zoekt".to_owned()],
                }),
            })
            .name(),
            "search"
        );
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
