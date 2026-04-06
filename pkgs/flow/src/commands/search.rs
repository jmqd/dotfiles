use crate::cli::{
    SearchArgs, SearchCodeArgs, SearchCommands, SearchCommitsArgs, SearchQueryArgs,
    SearchReindexArgs, SearchStatusArgs,
};
use crate::context::Ctx;
use crate::logging::tracing;
use crate::search::config::{SearchConfig, SearchState};
use crate::search::dirty;
use crate::search::metadata::{self, CommitMatch, CommitSearchFilters};
use crate::search::repo::{
    DiscoveredRepo, discover_repos, repo_from_working_dir, repo_has_head, resolve_repo_selector,
    write_repo_records,
};
use crate::search::zoekt::{self, ZoektMatch};
use crate::search::{SearchTools, join_query_terms, normalize_query_terms};
use chrono::Utc;
use serde::Serialize;
use std::fmt::Write as _;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "command", content = "data", rename_all = "kebab-case")]
pub enum SearchOutput {
    Query(SearchResultsOutput),
    Code(SearchResultsOutput),
    Commits(SearchResultsOutput),
    Reindex(ReindexOutput),
    Status(StatusOutput),
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SearchResultsOutput {
    pub query: String,
    pub repo: Option<String>,
    pub results: Vec<SearchResult>,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum SearchResult {
    Code {
        repo: String,
        path: String,
        line: u32,
        snippet: String,
    },
    Path {
        repo: String,
        path: String,
    },
    Commit {
        repo: String,
        commit: String,
        author: String,
        author_email: String,
        authored_at: String,
        subject: String,
        body: String,
        changed_files: Vec<String>,
    },
    Dirty {
        repo: String,
        path: String,
        line: usize,
        snippet: String,
    },
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ReindexOutput {
    pub roots: Vec<String>,
    pub repo_count: usize,
    pub indexed_repo_count: usize,
    pub commit_count: usize,
    pub last_reindex_at: String,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct StatusOutput {
    pub roots: Vec<String>,
    pub state_dir: String,
    pub zoekt_index_dir: String,
    pub metadata_db_path: String,
    pub repos_manifest_path: String,
    pub service_endpoint: String,
    pub service_running: bool,
    pub index_ready: bool,
    pub metadata_ready: bool,
    pub indexed_repo_count: usize,
    pub commit_count: usize,
    pub last_reindex_at: Option<String>,
}

pub fn execute(ctx: &Ctx, args: SearchArgs) -> anyhow::Result<SearchOutput> {
    let config = SearchConfig::load()?;
    let tools = SearchTools::load();

    match args.command {
        SearchCommands::Query(args) => Ok(SearchOutput::Query(execute_query(
            ctx, &config, &tools, args,
        )?)),
        SearchCommands::Code(args) => Ok(SearchOutput::Code(execute_code(
            ctx, &config, &tools, args,
        )?)),
        SearchCommands::Commits(args) => {
            Ok(SearchOutput::Commits(execute_commits(ctx, &config, args)?))
        }
        SearchCommands::Reindex(args) => Ok(SearchOutput::Reindex(execute_reindex(
            ctx, &config, &tools, args,
        )?)),
        SearchCommands::Status(args) => Ok(SearchOutput::Status(execute_status(&config, args)?)),
    }
}

pub fn format_text(output: &SearchOutput) -> String {
    match output {
        SearchOutput::Query(output)
        | SearchOutput::Code(output)
        | SearchOutput::Commits(output) => format_search_results(output),
        SearchOutput::Reindex(output) => format_reindex(output),
        SearchOutput::Status(output) => format_status(output),
    }
}

fn execute_query(
    ctx: &Ctx,
    config: &SearchConfig,
    tools: &SearchTools,
    args: SearchQueryArgs,
) -> anyhow::Result<SearchResultsOutput> {
    if args.no_code && args.no_commits && !args.include_dirty {
        anyhow::bail!(
            "search query has no enabled backends; remove --no-code/--no-commits or add --include-dirty"
        );
    }

    let query = join_query_terms(&args.terms);
    let normalized_terms = normalize_query_terms(&args.terms);
    let selected_repo = resolve_optional_repo(config, ctx, args.scope.repo.as_deref())?;
    let mut results = Vec::new();
    let mut warnings = Vec::new();
    let mut used_backend = false;

    tracing::debug!(query = %query, repo = ?selected_repo.as_ref().map(|repo| repo.display_name.as_str()), include_dirty = args.include_dirty, "executing flow search query");

    if !args.no_code {
        if config.index_exists()? {
            used_backend = true;
            results.extend(
                zoekt::search(
                    config,
                    tools.zoekt_bin(),
                    &query,
                    selected_repo.as_ref(),
                    args.scope.path.as_deref(),
                    args.scope.limit,
                )?
                .into_iter()
                .map(convert_zoekt_match),
            );
        } else {
            warnings.push(format!(
                "Zoekt index is missing at {}; run `flow search reindex` to enable code search",
                config.zoekt_index_dir.display()
            ));
        }
    }

    if !args.no_commits {
        if config.metadata_exists() {
            used_backend = true;
            let filters = build_commit_filters(
                &normalized_terms,
                selected_repo.as_ref(),
                args.scope.path.as_deref(),
                args.author.as_deref(),
                args.since.as_deref(),
                args.scope.limit,
            )?;
            results.extend(
                metadata::search_commits(config, &filters)?
                    .into_iter()
                    .map(convert_commit_match),
            );
        } else {
            warnings.push(format!(
                "commit metadata index is missing at {}; run `flow search reindex` to enable commit search",
                config.metadata_db_path.display()
            ));
        }
    }

    if args.include_dirty {
        match selected_repo
            .clone()
            .or_else(|| repo_from_working_dir(config, ctx.working_dir()))
        {
            Some(repo) => {
                used_backend = true;
                results.extend(
                    dirty::search_repo(
                        config,
                        tools.git_bin(),
                        &repo,
                        &normalized_terms,
                        args.scope.path.as_deref(),
                        args.scope.limit,
                    )?
                    .into_iter()
                    .map(|entry| SearchResult::Dirty {
                        repo: entry.repo,
                        path: entry.path,
                        line: entry.line,
                        snippet: entry.snippet,
                    }),
                );
            }
            None => warnings.push(
                "dirty search was requested, but the current directory is not inside a git repo and no --repo was provided".to_owned(),
            ),
        }
    }

    if !used_backend {
        anyhow::bail!(
            "no search backend is available; run `flow search reindex` or use --include-dirty inside a repo"
        );
    }

    Ok(SearchResultsOutput {
        query,
        repo: selected_repo.map(|repo| repo.display_name),
        results,
        warnings,
    })
}

fn execute_code(
    ctx: &Ctx,
    config: &SearchConfig,
    tools: &SearchTools,
    args: SearchCodeArgs,
) -> anyhow::Result<SearchResultsOutput> {
    if !config.index_exists()? {
        anyhow::bail!(
            "Zoekt index is missing at {}; run `flow search reindex` first",
            config.zoekt_index_dir.display()
        );
    }

    let query = join_query_terms(&args.terms);
    let selected_repo = resolve_optional_repo(config, ctx, args.scope.repo.as_deref())?;
    let results = zoekt::search(
        config,
        tools.zoekt_bin(),
        &query,
        selected_repo.as_ref(),
        args.scope.path.as_deref(),
        args.scope.limit,
    )?
    .into_iter()
    .map(convert_zoekt_match)
    .collect();

    Ok(SearchResultsOutput {
        query,
        repo: selected_repo.map(|repo| repo.display_name),
        results,
        warnings: Vec::new(),
    })
}

fn execute_commits(
    ctx: &Ctx,
    config: &SearchConfig,
    args: SearchCommitsArgs,
) -> anyhow::Result<SearchResultsOutput> {
    if !config.metadata_exists() {
        anyhow::bail!(
            "commit metadata index is missing at {}; run `flow search reindex` first",
            config.metadata_db_path.display()
        );
    }

    let query = join_query_terms(&args.terms);
    let normalized_terms = normalize_query_terms(&args.terms);
    let selected_repo = resolve_optional_repo(config, ctx, args.scope.repo.as_deref())?;
    let filters = build_commit_filters(
        &normalized_terms,
        selected_repo.as_ref(),
        args.scope.path.as_deref(),
        args.author.as_deref(),
        args.since.as_deref(),
        args.scope.limit,
    )?;
    let results = metadata::search_commits(config, &filters)?
        .into_iter()
        .map(convert_commit_match)
        .collect();

    Ok(SearchResultsOutput {
        query,
        repo: selected_repo.map(|repo| repo.display_name),
        results,
        warnings: Vec::new(),
    })
}

fn execute_reindex(
    _ctx: &Ctx,
    config: &SearchConfig,
    tools: &SearchTools,
    _args: SearchReindexArgs,
) -> anyhow::Result<ReindexOutput> {
    let discovered_repos = discover_repos(config)?;
    let mut indexable_repos = Vec::new();
    let mut warnings = Vec::new();

    for repo in &discovered_repos {
        if repo_has_head(tools.git_bin(), &repo.path) {
            indexable_repos.push(repo.clone());
        } else {
            warnings.push(format!(
                "skipping {} because it does not have a HEAD commit yet",
                repo.display_name
            ));
        }
    }

    let zoekt_stats = zoekt::reindex(config, tools.zoekt_git_index_bin(), &indexable_repos)?;
    let metadata_stats = metadata::reindex(config, tools.git_bin(), &indexable_repos)?;
    write_repo_records(config, &discovered_repos)?;

    let last_reindex_at = Utc::now().to_rfc3339();
    config.write_state(&SearchState {
        last_reindex_at: Some(last_reindex_at.clone()),
        repo_count: discovered_repos.len(),
        commit_count: metadata_stats.commit_count,
    })?;

    Ok(ReindexOutput {
        roots: config
            .roots
            .iter()
            .map(|root| root.display().to_string())
            .collect(),
        repo_count: discovered_repos.len(),
        indexed_repo_count: zoekt_stats.indexed_repo_count,
        commit_count: metadata_stats.commit_count,
        last_reindex_at,
        warnings,
    })
}

fn execute_status(config: &SearchConfig, _args: SearchStatusArgs) -> anyhow::Result<StatusOutput> {
    let state = config.load_state()?;
    Ok(StatusOutput {
        roots: config
            .roots
            .iter()
            .map(|root| root.display().to_string())
            .collect(),
        state_dir: config.state_dir.display().to_string(),
        zoekt_index_dir: config.zoekt_index_dir.display().to_string(),
        metadata_db_path: config.metadata_db_path.display().to_string(),
        repos_manifest_path: config.repos_manifest_path.display().to_string(),
        service_endpoint: config.zoekt_listen.clone(),
        service_running: is_service_running(&config.zoekt_listen),
        index_ready: config.index_exists()?,
        metadata_ready: config.metadata_exists(),
        indexed_repo_count: state.repo_count,
        commit_count: state.commit_count,
        last_reindex_at: state.last_reindex_at,
    })
}

fn resolve_optional_repo(
    config: &SearchConfig,
    ctx: &Ctx,
    selector: Option<&str>,
) -> anyhow::Result<Option<DiscoveredRepo>> {
    selector
        .map(|selector| resolve_repo_selector(config, selector, ctx.working_dir()))
        .transpose()
}

fn build_commit_filters(
    normalized_terms: &[String],
    selected_repo: Option<&DiscoveredRepo>,
    path_filter: Option<&str>,
    author_filter: Option<&str>,
    since: Option<&str>,
    limit: usize,
) -> anyhow::Result<CommitSearchFilters> {
    Ok(CommitSearchFilters {
        repo_path: selected_repo.map(|repo| repo.path.display().to_string()),
        path_filter: path_filter.map(|value| value.to_lowercase()),
        author_filter: author_filter.map(|value| value.to_lowercase()),
        since_unix: since.map(metadata::parse_since_argument).transpose()?,
        terms: normalized_terms.to_vec(),
        limit,
    })
}

fn convert_zoekt_match(entry: ZoektMatch) -> SearchResult {
    if entry.is_path_match {
        SearchResult::Path {
            repo: entry.repo,
            path: entry.path,
        }
    } else {
        SearchResult::Code {
            repo: entry.repo,
            path: entry.path,
            line: entry.line.unwrap_or_default(),
            snippet: entry.snippet,
        }
    }
}

fn convert_commit_match(entry: CommitMatch) -> SearchResult {
    SearchResult::Commit {
        repo: entry.repo,
        commit: entry.commit,
        author: entry.author,
        author_email: entry.author_email,
        authored_at: entry.authored_at,
        subject: entry.subject,
        body: entry.body,
        changed_files: entry.changed_files,
    }
}

fn is_service_running(endpoint: &str) -> bool {
    let timeout = Duration::from_millis(300);
    endpoint
        .to_socket_addrs()
        .ok()
        .into_iter()
        .flatten()
        .any(|address| TcpStream::connect_timeout(&address, timeout).is_ok())
}

fn format_search_results(output: &SearchResultsOutput) -> String {
    let mut rendered = String::new();
    let scope = output
        .repo
        .as_deref()
        .map(|repo| format!(" in {repo}"))
        .unwrap_or_default();
    let _ = writeln!(&mut rendered, "Query: {}{}", output.query, scope);

    let code_matches = output
        .results
        .iter()
        .filter_map(|result| match result {
            SearchResult::Code {
                repo,
                path,
                line,
                snippet,
            } => Some((repo, path, line, snippet)),
            _ => None,
        })
        .collect::<Vec<_>>();
    let path_matches = output
        .results
        .iter()
        .filter_map(|result| match result {
            SearchResult::Path { repo, path } => Some((repo, path)),
            _ => None,
        })
        .collect::<Vec<_>>();
    let commit_matches = output
        .results
        .iter()
        .filter_map(|result| match result {
            SearchResult::Commit {
                repo,
                commit,
                author,
                authored_at,
                subject,
                changed_files,
                ..
            } => Some((repo, commit, author, authored_at, subject, changed_files)),
            _ => None,
        })
        .collect::<Vec<_>>();
    let dirty_matches = output
        .results
        .iter()
        .filter_map(|result| match result {
            SearchResult::Dirty {
                repo,
                path,
                line,
                snippet,
            } => Some((repo, path, line, snippet)),
            _ => None,
        })
        .collect::<Vec<_>>();

    if code_matches.is_empty()
        && path_matches.is_empty()
        && commit_matches.is_empty()
        && dirty_matches.is_empty()
    {
        let _ = writeln!(&mut rendered, "No results.");
    }

    if !code_matches.is_empty() {
        let _ = writeln!(&mut rendered, "\nCode matches");
        for (repo, path, line, snippet) in code_matches {
            let _ = writeln!(&mut rendered, "- [{repo}] {path}:{line}: {snippet}");
        }
    }

    if !path_matches.is_empty() {
        let _ = writeln!(&mut rendered, "\nPath matches");
        for (repo, path) in path_matches {
            let _ = writeln!(&mut rendered, "- [{repo}] {path}");
        }
    }

    if !commit_matches.is_empty() {
        let _ = writeln!(&mut rendered, "\nCommit matches");
        for (repo, commit, author, authored_at, subject, changed_files) in commit_matches {
            let files = if changed_files.is_empty() {
                String::new()
            } else {
                format!(" ({})", changed_files.join(", "))
            };
            let _ = writeln!(
                &mut rendered,
                "- [{repo}] {commit} {authored_at} {author}: {subject}{files}"
            );
        }
    }

    if !dirty_matches.is_empty() {
        let _ = writeln!(&mut rendered, "\nDirty working tree matches");
        for (repo, path, line, snippet) in dirty_matches {
            let _ = writeln!(&mut rendered, "- [{repo}] {path}:{line}: {snippet}");
        }
    }

    if !output.warnings.is_empty() {
        let _ = writeln!(&mut rendered, "\nWarnings");
        for warning in &output.warnings {
            let _ = writeln!(&mut rendered, "- {warning}");
        }
    }

    rendered.trim_end().to_owned()
}

fn format_reindex(output: &ReindexOutput) -> String {
    let mut rendered = String::new();
    let _ = writeln!(
        &mut rendered,
        "reindexed {} repos",
        output.indexed_repo_count
    );
    let _ = writeln!(&mut rendered, "discovered_repos: {}", output.repo_count);
    let _ = writeln!(
        &mut rendered,
        "indexed_repos: {}",
        output.indexed_repo_count
    );
    let _ = writeln!(&mut rendered, "indexed_commits: {}", output.commit_count);
    let _ = writeln!(&mut rendered, "last_reindex_at: {}", output.last_reindex_at);
    if !output.warnings.is_empty() {
        let _ = writeln!(&mut rendered, "warnings:");
        for warning in &output.warnings {
            let _ = writeln!(&mut rendered, "- {warning}");
        }
    }
    rendered.trim_end().to_owned()
}

fn format_status(output: &StatusOutput) -> String {
    let mut rendered = String::new();
    let _ = writeln!(&mut rendered, "roots: {}", output.roots.join(", "));
    let _ = writeln!(&mut rendered, "state_dir: {}", output.state_dir);
    let _ = writeln!(&mut rendered, "zoekt_index_dir: {}", output.zoekt_index_dir);
    let _ = writeln!(
        &mut rendered,
        "metadata_db_path: {}",
        output.metadata_db_path
    );
    let _ = writeln!(
        &mut rendered,
        "repos_manifest_path: {}",
        output.repos_manifest_path
    );
    let _ = writeln!(
        &mut rendered,
        "service_endpoint: {}",
        output.service_endpoint
    );
    let _ = writeln!(&mut rendered, "service_running: {}", output.service_running);
    let _ = writeln!(&mut rendered, "index_ready: {}", output.index_ready);
    let _ = writeln!(&mut rendered, "metadata_ready: {}", output.metadata_ready);
    let _ = writeln!(
        &mut rendered,
        "indexed_repo_count: {}",
        output.indexed_repo_count
    );
    let _ = writeln!(&mut rendered, "commit_count: {}", output.commit_count);
    let _ = writeln!(
        &mut rendered,
        "last_reindex_at: {}",
        output.last_reindex_at.as_deref().unwrap_or("never")
    );
    rendered.trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use super::{SearchOutput, SearchResult, SearchResultsOutput, format_text};

    #[test]
    fn formats_grouped_search_text() {
        let output = SearchOutput::Query(SearchResultsOutput {
            query: "review scope".to_owned(),
            repo: Some("dotfiles".to_owned()),
            results: vec![
                SearchResult::Code {
                    repo: "dotfiles".to_owned(),
                    path: "src/main.rs".to_owned(),
                    line: 42,
                    snippet: "let scope = parse_scope();".to_owned(),
                },
                SearchResult::Commit {
                    repo: "dotfiles".to_owned(),
                    commit: "abc123".to_owned(),
                    author: "Jane".to_owned(),
                    author_email: "jane@example.com".to_owned(),
                    authored_at: "2026-04-06T15:00:00+00:00".to_owned(),
                    subject: "pi/review: harden parsing".to_owned(),
                    body: String::new(),
                    changed_files: vec![
                        "home/.pi/agent/extensions/review-orchestrator/core.ts".to_owned(),
                    ],
                },
                SearchResult::Dirty {
                    repo: "dotfiles".to_owned(),
                    path: "bin/hive".to_owned(),
                    line: 12,
                    snippet: "echo dirty".to_owned(),
                },
            ],
            warnings: vec!["example warning".to_owned()],
        });

        let rendered = format_text(&output);
        assert!(rendered.contains("Query: review scope in dotfiles"));
        assert!(rendered.contains("Code matches"));
        assert!(rendered.contains("Commit matches"));
        assert!(rendered.contains("Dirty working tree matches"));
        assert!(rendered.contains("Warnings"));
    }
}
