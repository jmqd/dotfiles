use crate::search::config::SearchConfig;
use crate::search::repo::DiscoveredRepo;
use anyhow::{Context as _, bail};
use chrono::{DateTime, NaiveDate, Utc};
use rusqlite::{Connection, params, params_from_iter, types::Value};
use serde::Serialize;
use std::fs;
use std::process::Command;
use tempfile::NamedTempFile;

#[derive(Clone, Debug, Eq, PartialEq)]
struct CommitRecord {
    repo_name: String,
    repo_path: String,
    commit_id: String,
    author_name: String,
    author_email: String,
    authored_at: i64,
    subject: String,
    body: String,
    changed_files: Vec<String>,
    search_text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CommitMatch {
    pub repo: String,
    pub commit: String,
    pub author: String,
    pub author_email: String,
    pub authored_at: String,
    pub subject: String,
    pub body: String,
    pub changed_files: Vec<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MetadataReindexStats {
    pub commit_count: usize,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CommitSearchFilters {
    pub repo_path: Option<String>,
    pub path_filter: Option<String>,
    pub author_filter: Option<String>,
    pub since_unix: Option<i64>,
    pub terms: Vec<String>,
    pub limit: usize,
}

pub fn reindex(
    config: &SearchConfig,
    git_bin: &str,
    repos: &[DiscoveredRepo],
) -> anyhow::Result<MetadataReindexStats> {
    config.ensure_state_dirs()?;
    let temporary_file = NamedTempFile::new_in(&config.metadata_dir).with_context(|| {
        format!(
            "failed to create temp database in {}",
            config.metadata_dir.display()
        )
    })?;
    let temporary_path = temporary_file.path().to_path_buf();
    drop(temporary_file);

    let connection = Connection::open(&temporary_path)
        .with_context(|| format!("failed to open {}", temporary_path.display()))?;
    initialize_schema(&connection)?;

    let mut commit_count = 0usize;
    for repo in repos {
        let commits = collect_repo_commits(git_bin, repo)?;
        insert_commits(&connection, &commits)?;
        commit_count += commits.len();
    }
    connection
        .execute_batch("PRAGMA optimize;")
        .context("failed to optimize metadata database")?;
    drop(connection);

    if config.metadata_db_path.exists() {
        fs::remove_file(&config.metadata_db_path)
            .with_context(|| format!("failed to remove {}", config.metadata_db_path.display()))?;
    }
    fs::rename(&temporary_path, &config.metadata_db_path).with_context(|| {
        format!(
            "failed to move {} to {}",
            temporary_path.display(),
            config.metadata_db_path.display()
        )
    })?;

    Ok(MetadataReindexStats { commit_count })
}

pub fn search_commits(
    config: &SearchConfig,
    filters: &CommitSearchFilters,
) -> anyhow::Result<Vec<CommitMatch>> {
    if !config.metadata_db_path.exists() {
        bail!(
            "commit metadata index not found at {}; run `flow search reindex` first",
            config.metadata_db_path.display()
        );
    }

    let connection = Connection::open(&config.metadata_db_path)
        .with_context(|| format!("failed to open {}", config.metadata_db_path.display()))?;
    let mut query = String::from(
        "SELECT repo_name, commit_id, author_name, author_email, authored_at, subject, body, changed_files FROM commits WHERE 1 = 1",
    );
    let mut params = Vec::<Value>::new();

    if let Some(repo_path) = &filters.repo_path {
        query.push_str(" AND repo_path = ?");
        params.push(Value::Text(repo_path.clone()));
    }
    if let Some(path_filter) = &filters.path_filter {
        query.push_str(" AND changed_files LIKE ? ESCAPE '\\'");
        params.push(Value::Text(format!(
            "%{}%",
            escape_like_pattern(&path_filter.to_lowercase())
        )));
    }
    if let Some(author_filter) = &filters.author_filter {
        query.push_str(" AND (lower(author_name) LIKE ? ESCAPE '\\' OR lower(author_email) LIKE ? ESCAPE '\\')");
        let pattern = format!("%{}%", escape_like_pattern(&author_filter.to_lowercase()));
        params.push(Value::Text(pattern.clone()));
        params.push(Value::Text(pattern));
    }
    if let Some(since_unix) = filters.since_unix {
        query.push_str(" AND authored_at >= ?");
        params.push(Value::Integer(since_unix));
    }
    for term in &filters.terms {
        query.push_str(" AND search_text LIKE ? ESCAPE '\\'");
        params.push(Value::Text(format!(
            "%{}%",
            escape_like_pattern(&term.to_lowercase())
        )));
    }

    query.push_str(" ORDER BY authored_at DESC, repo_name ASC LIMIT ?");
    params.push(Value::Integer(filters.limit as i64));

    let mut statement = connection.prepare(&query)?;
    let rows = statement.query_map(params_from_iter(params.iter()), |row| {
        let changed_files = row.get::<_, String>(7)?;
        Ok(CommitMatch {
            repo: row.get(0)?,
            commit: row.get(1)?,
            author: row.get(2)?,
            author_email: row.get(3)?,
            authored_at: format_timestamp(row.get(4)?),
            subject: row.get(5)?,
            body: row.get::<_, String>(6)?.trim_end().to_owned(),
            changed_files: changed_files
                .split('\n')
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect(),
        })
    })?;

    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn parse_since_argument(value: &str) -> anyhow::Result<i64> {
    if let Ok(timestamp) = value.parse::<i64>() {
        return Ok(timestamp);
    }

    if let Ok(parsed) = DateTime::parse_from_rfc3339(value) {
        return Ok(parsed.with_timezone(&Utc).timestamp());
    }

    if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
        let date_time = date
            .and_hms_opt(0, 0, 0)
            .context("failed to construct midnight timestamp")?;
        return Ok(date_time.and_utc().timestamp());
    }

    bail!("unsupported --since value {value}; use YYYY-MM-DD, RFC3339, or unix seconds")
}

fn initialize_schema(connection: &Connection) -> anyhow::Result<()> {
    connection.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;

        CREATE TABLE commits (
            repo_name TEXT NOT NULL,
            repo_path TEXT NOT NULL,
            commit_id TEXT NOT NULL,
            author_name TEXT NOT NULL,
            author_email TEXT NOT NULL,
            authored_at INTEGER NOT NULL,
            subject TEXT NOT NULL,
            body TEXT NOT NULL,
            changed_files TEXT NOT NULL,
            search_text TEXT NOT NULL,
            PRIMARY KEY (repo_path, commit_id)
        );

        CREATE INDEX idx_commits_repo_name ON commits(repo_name);
        CREATE INDEX idx_commits_repo_path ON commits(repo_path);
        CREATE INDEX idx_commits_authored_at ON commits(authored_at DESC);
        "#,
    )?;
    Ok(())
}

fn insert_commits(connection: &Connection, commits: &[CommitRecord]) -> anyhow::Result<()> {
    let transaction = connection.unchecked_transaction()?;
    {
        let mut statement = transaction.prepare(
            r#"
            INSERT INTO commits (
                repo_name,
                repo_path,
                commit_id,
                author_name,
                author_email,
                authored_at,
                subject,
                body,
                changed_files,
                search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )?;

        for commit in commits {
            statement.execute(params![
                commit.repo_name,
                commit.repo_path,
                commit.commit_id,
                commit.author_name,
                commit.author_email,
                commit.authored_at,
                commit.subject,
                commit.body,
                commit.changed_files.join("\n").to_lowercase(),
                commit.search_text,
            ])?;
        }
    }
    transaction.commit()?;
    Ok(())
}

fn collect_repo_commits(git_bin: &str, repo: &DiscoveredRepo) -> anyhow::Result<Vec<CommitRecord>> {
    let repo_display = repo.path.display().to_string();
    let output = Command::new(git_bin)
        .arg("-C")
        .arg(&repo_display)
        .args([
            "log",
            "--all",
            "--date=unix",
            "--no-renames",
            "--format=%x1e%H%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1d",
            "--name-only",
            "-z",
        ])
        .output()
        .with_context(|| format!("failed to run {git_bin} log for {}", repo.path.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("git log failed for {}: {stderr}", repo.path.display());
    }

    parse_git_log_output(repo, &output.stdout)
}

fn parse_git_log_output(repo: &DiscoveredRepo, bytes: &[u8]) -> anyhow::Result<Vec<CommitRecord>> {
    let mut commits = Vec::new();
    for record in bytes.split(|byte| *byte == 0x1e) {
        if record.is_empty() {
            continue;
        }
        let Some(separator_index) = record.iter().position(|byte| *byte == 0x1d) else {
            continue;
        };
        let header_bytes = &record[..separator_index];
        let raw_files_bytes = &record[separator_index + 1..];
        let header = String::from_utf8_lossy(header_bytes)
            .trim_start_matches('\n')
            .to_owned();
        let mut fields = header.split('\x1f');
        let commit_id = next_required(&mut fields, "commit id")?.to_owned();
        let author_name = next_required(&mut fields, "author name")?.to_owned();
        let author_email = next_required(&mut fields, "author email")?.to_owned();
        let authored_at = next_required(&mut fields, "authored at")?
            .parse::<i64>()
            .context("failed to parse authored timestamp")?;
        let subject = next_required(&mut fields, "subject")?.to_owned();
        let body = fields.collect::<Vec<_>>().join("\x1f");
        let changed_files = raw_files_bytes
            .split(|byte| *byte == 0)
            .filter_map(|entry| {
                let rendered = String::from_utf8_lossy(entry).trim().to_owned();
                if rendered.is_empty() {
                    None
                } else {
                    Some(rendered)
                }
            })
            .collect::<Vec<_>>();

        let search_text = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}",
            repo.display_name,
            commit_id,
            author_name,
            author_email,
            subject,
            body,
            changed_files.join("\n")
        )
        .to_lowercase();

        commits.push(CommitRecord {
            repo_name: repo.display_name.clone(),
            repo_path: repo.path.display().to_string(),
            commit_id,
            author_name,
            author_email,
            authored_at,
            subject,
            body,
            changed_files,
            search_text,
        });
    }

    Ok(commits)
}

fn next_required<'a>(
    fields: &mut impl Iterator<Item = &'a str>,
    field_name: &str,
) -> anyhow::Result<&'a str> {
    fields
        .next()
        .with_context(|| format!("missing {field_name} field in git log output"))
}

fn escape_like_pattern(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn format_timestamp(timestamp: i64) -> String {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.to_rfc3339())
        .unwrap_or_else(|| timestamp.to_string())
}

#[cfg(test)]
mod tests {
    use super::{escape_like_pattern, parse_git_log_output, parse_since_argument};
    use crate::search::repo::DiscoveredRepo;
    use std::path::PathBuf;

    #[test]
    fn parses_supported_since_values() {
        assert_eq!(
            parse_since_argument("1704067200").expect("timestamp parses"),
            1704067200
        );
        assert_eq!(
            parse_since_argument("2024-01-01").expect("date parses"),
            1704067200
        );
        assert_eq!(
            parse_since_argument("2024-01-01T00:00:00Z").expect("rfc3339 parses"),
            1704067200
        );
    }

    #[test]
    fn escapes_like_metacharacters() {
        assert_eq!(escape_like_pattern("hello_world%"), "hello\\_world\\%");
    }

    #[test]
    fn parses_git_log_records() {
        let repo = DiscoveredRepo {
            name: "dotfiles".to_owned(),
            display_name: "dotfiles".to_owned(),
            path: PathBuf::from("/tmp/dotfiles"),
            root: None,
        };
        let raw = b"\x1eabc123\x1fJane\x1fjane@example.com\x1f1704067200\x1fsubject\x1fbody line\n\x1d\0src/main.rs\0README.md\0";
        let commits = parse_git_log_output(&repo, raw).expect("git log parses");

        assert_eq!(commits.len(), 1);
        assert_eq!(commits[0].commit_id, "abc123");
        assert_eq!(commits[0].changed_files, vec!["src/main.rs", "README.md"]);
    }
}
