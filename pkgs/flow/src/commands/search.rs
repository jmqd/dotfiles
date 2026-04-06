use crate::cli::{
    SearchArgs, SearchCodeArgs, SearchCommands, SearchCommitsArgs, SearchQueryArgs,
    SearchReindexArgs, SearchStatusArgs,
};
use crate::context::Ctx;
use crate::logging::tracing;
use crate::search::config::{SearchConfig, SearchState};
use crate::search::dirty;
use crate::search::lock::FileLock;
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
    pub discovered_repo_count: usize,
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
    let _lock = FileLock::acquire(&config.reindex_lock_path)?;
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
        discovered_repo_count: discovered_repos.len(),
        indexed_repo_count: zoekt_stats.indexed_repo_count,
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
        discovered_repo_count: state.discovered_repo_count,
        indexed_repo_count: state.indexed_repo_count,
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
        "discovered_repo_count: {}",
        output.discovered_repo_count
    );
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
    use super::{
        ReindexOutput, SearchOutput, SearchResult, SearchResultsOutput, StatusOutput,
        execute_query, format_text,
    };
    use crate::cli::{CommonArgs, SearchQueryArgs, SearchScopeArgs};
    use crate::context::Ctx;
    use crate::output::OutputMode;
    use crate::search::SearchTools;
    use crate::search::config::SearchConfig;
    use crate::search::metadata;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::{Mutex, OnceLock};
    use tempfile::TempDir;

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

    #[test]
    fn formats_code_commits_reindex_and_status_outputs() {
        let code_rendered = format_text(&SearchOutput::Code(SearchResultsOutput {
            query: "needle".to_owned(),
            repo: None,
            results: vec![SearchResult::Code {
                repo: "dotfiles".to_owned(),
                path: "src/main.rs".to_owned(),
                line: 7,
                snippet: "needle();".to_owned(),
            }],
            warnings: Vec::new(),
        }));
        assert!(code_rendered.contains("Code matches"));

        let commits_rendered = format_text(&SearchOutput::Commits(SearchResultsOutput {
            query: "needle".to_owned(),
            repo: None,
            results: vec![SearchResult::Commit {
                repo: "dotfiles".to_owned(),
                commit: "abc123".to_owned(),
                author: "Jane".to_owned(),
                author_email: "jane@example.com".to_owned(),
                authored_at: "2026-04-06T15:00:00+00:00".to_owned(),
                subject: "search: add tests".to_owned(),
                body: String::new(),
                changed_files: vec!["src/main.rs".to_owned()],
            }],
            warnings: Vec::new(),
        }));
        assert!(commits_rendered.contains("Commit matches"));

        let reindex_rendered = format_text(&SearchOutput::Reindex(ReindexOutput {
            roots: vec!["/src".to_owned()],
            repo_count: 2,
            indexed_repo_count: 1,
            commit_count: 4,
            last_reindex_at: "2026-04-06T00:00:00Z".to_owned(),
            warnings: vec!["skipped repo".to_owned()],
        }));
        assert!(reindex_rendered.contains("reindexed 1 repos"));
        assert!(reindex_rendered.contains("warnings:"));

        let status_rendered = format_text(&SearchOutput::Status(StatusOutput {
            roots: vec!["/src".to_owned()],
            state_dir: "/state".to_owned(),
            zoekt_index_dir: "/state/zoekt/index".to_owned(),
            metadata_db_path: "/state/metadata/commits.sqlite".to_owned(),
            repos_manifest_path: "/state/metadata/repos.json".to_owned(),
            service_endpoint: "127.0.0.1:6070".to_owned(),
            service_running: true,
            index_ready: true,
            metadata_ready: true,
            discovered_repo_count: 5,
            indexed_repo_count: 3,
            commit_count: 42,
            last_reindex_at: Some("2026-04-06T00:00:00Z".to_owned()),
        }));
        assert!(status_rendered.contains("discovered_repo_count: 5"));
        assert!(status_rendered.contains("indexed_repo_count: 3"));
    }

    #[test]
    fn rejects_query_when_all_backends_are_disabled() {
        let sandbox = TempDir::new().expect("tempdir");
        let config = test_config(sandbox.path().join("src"), sandbox.path().join("state"));
        let ctx = test_ctx(sandbox.path());
        let error = execute_query(
            &ctx,
            &config,
            &test_tools(empty_zoekt_script(sandbox.path())),
            SearchQueryArgs {
                scope: default_scope(),
                author: None,
                since: None,
                include_dirty: false,
                no_code: true,
                no_commits: true,
                terms: vec!["review".to_owned()],
            },
        )
        .expect_err("query should fail");

        assert!(error
            .to_string()
            .contains("search query has no enabled backends"));
    }

    #[test]
    fn missing_code_index_still_allows_commit_backend() {
        let sandbox = TempDir::new().expect("tempdir");
        let config = test_config(sandbox.path().join("src"), sandbox.path().join("state"));
        config.ensure_state_dirs().expect("state dirs");
        metadata::reindex(&config, "git", &[]).expect("metadata db created");
        let ctx = test_ctx(sandbox.path());

        let output = execute_query(
            &ctx,
            &config,
            &test_tools(empty_zoekt_script(sandbox.path())),
            SearchQueryArgs {
                scope: default_scope(),
                author: None,
                since: None,
                include_dirty: false,
                no_code: false,
                no_commits: false,
                terms: vec!["review".to_owned()],
            },
        )
        .expect("commit backend remains usable");

        assert!(output.results.is_empty());
        assert_eq!(output.warnings.len(), 1);
        assert!(output.warnings[0].contains("Zoekt index is missing"));
        assert!(output.warnings[0].contains("flow search reindex"));
    }

    #[test]
    fn missing_metadata_index_still_allows_code_backend() {
        let sandbox = TempDir::new().expect("tempdir");
        let config = test_config(sandbox.path().join("src"), sandbox.path().join("state"));
        fs::create_dir_all(&config.zoekt_index_dir).expect("create index dir");
        fs::write(config.zoekt_index_dir.join("test.zoekt"), b"").expect("write index shard");
        let ctx = test_ctx(sandbox.path());

        let output = execute_query(
            &ctx,
            &config,
            &test_tools(empty_zoekt_script(sandbox.path())),
            SearchQueryArgs {
                scope: default_scope(),
                author: None,
                since: None,
                include_dirty: false,
                no_code: false,
                no_commits: false,
                terms: vec!["review".to_owned()],
            },
        )
        .expect("code backend remains usable");

        assert!(output.results.is_empty());
        assert_eq!(output.warnings.len(), 1);
        assert!(output.warnings[0].contains("commit metadata index is missing"));
        assert!(output.warnings[0].contains("flow search reindex"));
    }

    #[test]
    fn include_dirty_outside_repo_warns_when_commit_backend_is_active() {
        let sandbox = TempDir::new().expect("tempdir");
        let config = test_config(sandbox.path().join("src"), sandbox.path().join("state"));
        config.ensure_state_dirs().expect("state dirs");
        metadata::reindex(&config, "git", &[]).expect("metadata db created");
        let outside_repo = sandbox.path().join("outside-repo");
        fs::create_dir_all(&outside_repo).expect("outside repo dir");
        let ctx = test_ctx(&outside_repo);

        let output = execute_query(
            &ctx,
            &config,
            &test_tools(empty_zoekt_script(sandbox.path())),
            SearchQueryArgs {
                scope: default_scope(),
                author: None,
                since: None,
                include_dirty: true,
                no_code: true,
                no_commits: false,
                terms: vec!["review".to_owned()],
            },
        )
        .expect("commit backend remains usable");

        assert!(output.results.is_empty());
        assert_eq!(output.warnings.len(), 1);
        assert!(output.warnings[0].contains("dirty search was requested"));
        assert!(output.warnings[0].contains("not inside a git repo"));
    }

    fn default_scope() -> SearchScopeArgs {
        SearchScopeArgs {
            repo: None,
            path: None,
            limit: 25,
        }
    }

    fn test_tools(zoekt_bin: String) -> SearchTools {
        let _guard = cwd_lock().lock().expect("env lock");
        unsafe {
            std::env::set_var("FLOW_SEARCH_GIT_BIN", "git");
            std::env::set_var("FLOW_SEARCH_ZOEKT_BIN", &zoekt_bin);
            std::env::set_var("FLOW_SEARCH_ZOEKT_GIT_INDEX_BIN", "zoekt-git-index");
        }
        let tools = SearchTools::load();
        unsafe {
            std::env::remove_var("FLOW_SEARCH_GIT_BIN");
            std::env::remove_var("FLOW_SEARCH_ZOEKT_BIN");
            std::env::remove_var("FLOW_SEARCH_ZOEKT_GIT_INDEX_BIN");
        }
        drop(_guard);
        tools
    }

    fn test_ctx(working_dir: &Path) -> Ctx {
        let _guard = cwd_lock().lock().expect("cwd lock");
        let previous = std::env::current_dir().expect("current dir");
        std::env::set_current_dir(working_dir).expect("set current dir");
        let ctx = Ctx::new(CommonArgs {
            automated: true,
            output: OutputMode::Json,
            log_format: None,
        })
        .expect("ctx builds");
        std::env::set_current_dir(previous).expect("restore current dir");
        drop(_guard);
        ctx
    }

    fn cwd_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn test_config(root: PathBuf, state_dir: PathBuf) -> SearchConfig {
        SearchConfig {
            roots: vec![root],
            zoekt_dir: state_dir.join("zoekt"),
            zoekt_index_dir: state_dir.join("zoekt/index"),
            metadata_dir: state_dir.join("metadata"),
            metadata_db_path: state_dir.join("metadata/commits.sqlite"),
            repos_manifest_path: state_dir.join("metadata/repos.json"),
            state_path: state_dir.join("state.json"),
            reindex_lock_path: state_dir.join("reindex.lock"),
            state_dir,
            zoekt_listen: "127.0.0.1:6070".to_owned(),
            excluded_dir_names: vec![
                ".direnv".to_owned(),
                ".git".to_owned(),
                "dist".to_owned(),
                "node_modules".to_owned(),
                "result".to_owned(),
                "target".to_owned(),
            ],
        }
    }

    fn empty_zoekt_script(root: &Path) -> String {
        let script_path = root.join("fake-zoekt.sh");
        fs::write(&script_path, "#!/bin/sh\nexit 0\n").expect("write zoekt script");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&script_path).expect("metadata").permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms).expect("chmod");
        }
        script_path.display().to_string()
    }
}
