use crate::logging::tracing;
use crate::search::config::SearchConfig;
use crate::search::repo::DiscoveredRepo;
use anyhow::{Context as _, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs;
use std::io::{Read as _, Write as _};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};
use tempfile::TempDir;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ZoektMatch {
    pub repo: String,
    pub path: String,
    pub line: Option<u32>,
    pub snippet: String,
    pub is_path_match: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ZoektReindexStats {
    pub indexed_repo_count: usize,
    /// The name zoekt gave each indexed repo, by repo path. zoekt prefers the
    /// origin remote's URL to anything flow could pass it.
    pub repo_names: BTreeMap<PathBuf, String>,
}

/// `heads` maps repo paths to the commit zoekt indexes; `previous_names` maps
/// them to the zoekt names the last reindex recorded, since zoekt writes no
/// shard for a repo it skips as up to date.
pub fn reindex(
    config: &SearchConfig,
    zoekt_git_index_bin: &str,
    repos: &[DiscoveredRepo],
    heads: &BTreeMap<PathBuf, String>,
    previous_names: &BTreeMap<PathBuf, String>,
) -> anyhow::Result<ZoektReindexStats> {
    config.ensure_state_dirs()?;
    let temporary_root = TempDir::new_in(&config.zoekt_dir).with_context(|| {
        format!(
            "failed to create temp dir in {}",
            config.zoekt_dir.display()
        )
    })?;
    let temporary_index_dir = temporary_root.path().join("index");
    fs::create_dir_all(&temporary_index_dir)
        .with_context(|| format!("failed to create {}", temporary_index_dir.display()))?;
    seed_with_current_shards(&config.zoekt_index_dir, &temporary_index_dir)?;

    let mut repo_names = BTreeMap::new();
    let mut contents = IndexContents::new();
    for repo in repos {
        let previous_name = previous_names.get(&repo.path).map(String::as_str);
        let name = index_repo(
            zoekt_git_index_bin,
            &temporary_index_dir,
            repo,
            previous_name,
        )?;
        // Repos sharing a name share shards, which hold the last one indexed.
        let version = heads.get(&repo.path).cloned().unwrap_or_default();
        contents.insert(name.clone(), IndexedRepo { version, shards: 0 });
        repo_names.insert(repo.path.clone(), name);
    }

    // Shards of repos that are gone or no longer indexable came along with the
    // seed; they must not stay searchable.
    for file_name in shard_files(&temporary_index_dir)?.into_keys() {
        match repo_name_from_shard(&file_name).and_then(|name| contents.get_mut(&name)) {
            Some(repo) => repo.shards += 1,
            None => {
                let path = temporary_index_dir.join(&file_name);
                fs::remove_file(&path)
                    .with_context(|| format!("failed to remove {}", path.display()))?;
            }
        }
    }
    let contents_path = temporary_index_dir.join(INDEX_CONTENTS_FILE);
    fs::write(&contents_path, serde_json::to_vec(&contents)?)
        .with_context(|| format!("failed to write {}", contents_path.display()))?;

    if config.zoekt_index_dir.exists() {
        fs::remove_dir_all(&config.zoekt_index_dir)
            .with_context(|| format!("failed to remove {}", config.zoekt_index_dir.display()))?;
    }
    fs::rename(&temporary_index_dir, &config.zoekt_index_dir).with_context(|| {
        format!(
            "failed to move {} to {}",
            temporary_index_dir.display(),
            config.zoekt_index_dir.display()
        )
    })?;

    Ok(ZoektReindexStats {
        indexed_repo_count: repos.len(),
        repo_names,
    })
}

/// Indexes one repo and returns the name zoekt gave it.
fn index_repo(
    zoekt_git_index_bin: &str,
    index_dir: &Path,
    repo: &DiscoveredRepo,
    previous_name: Option<&str>,
) -> anyhow::Result<String> {
    let mut written = run_zoekt_git_index(zoekt_git_index_bin, index_dir, repo, true)?;
    if written.is_empty() {
        let shards = shard_files(index_dir)?;
        let has_shard = |name: &str| {
            shards
                .keys()
                .any(|file_name| repo_name_from_shard(file_name).as_deref() == Some(name))
        };
        if let Some(name) = previous_name.filter(|name| has_shard(name)) {
            return Ok(name.to_owned());
        }
        // No record says which up-to-date shard is this repo's, so write it
        // again to learn its name.
        written = run_zoekt_git_index(zoekt_git_index_bin, index_dir, repo, false)?;
    }
    written_repo_name(written)
        .with_context(|| format!("reading the zoekt shard for {}", repo.path.display()))
}

/// Written beside the shards and swapped in with them, so the index
/// directory says which commit of each repo it holds; zoekt only loads
/// `*.zoekt` files.
const INDEX_CONTENTS_FILE: &str = "flow-index.json";

/// What an index directory holds, by zoekt repo name.
type IndexContents = BTreeMap<String, IndexedRepo>;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct IndexedRepo {
    /// The commit zoekt indexed.
    version: String,
    shards: usize,
}

/// Hard-links the live shards into the new index directory, so
/// `zoekt-git-index` skips repos whose shards are up to date. zoekt replaces a
/// shard by renaming a new file over it, which leaves the live link intact.
/// If linking fails, the new index starts empty and every repo is indexed.
fn seed_with_current_shards(current: &Path, temporary: &Path) -> anyhow::Result<()> {
    if !current.exists() {
        return Ok(());
    }
    for file_name in shard_files(current)?.into_keys() {
        if let Err(error) = fs::hard_link(current.join(&file_name), temporary.join(&file_name)) {
            tracing::warn!(error = %error, "cannot link the current zoekt shards; indexing every repo");
            fs::remove_dir_all(temporary)
                .and_then(|()| fs::create_dir_all(temporary))
                .with_context(|| format!("failed to empty {}", temporary.display()))?;
            return Ok(());
        }
    }
    Ok(())
}

/// Runs `zoekt-git-index` for one repo and returns the shard files it wrote.
fn run_zoekt_git_index(
    zoekt_git_index_bin: &str,
    index_dir: &Path,
    repo: &DiscoveredRepo,
    incremental: bool,
) -> anyhow::Result<Vec<String>> {
    let repo_cache = repo.root.as_ref().unwrap_or(&repo.path);
    let before = shard_files(index_dir)?;
    let output = Command::new(zoekt_git_index_bin)
        .arg(format!("-incremental={incremental}"))
        .arg("-index")
        .arg(index_dir)
        .arg("-repo_cache")
        .arg(repo_cache)
        .arg(&repo.path)
        .output()
        .with_context(|| {
            format!(
                "failed to run {} for {}",
                zoekt_git_index_bin,
                repo.path.display()
            )
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!(
            "zoekt indexing failed for {}: {stderr}",
            repo.path.display()
        );
    }
    Ok(shard_files(index_dir)?
        .into_iter()
        .filter(|(file_name, identity)| before.get(file_name) != Some(identity))
        .map(|(file_name, _)| file_name)
        .collect())
}

/// Each shard file by name, with the identity of the file behind the name.
/// zoekt writes a shard to a temp file and renames it into place, so a
/// rewritten shard has a new inode.
fn shard_files(dir: &Path) -> anyhow::Result<BTreeMap<String, (u64, SystemTime)>> {
    let mut shards = BTreeMap::new();
    for entry in fs::read_dir(dir).with_context(|| format!("failed to list {}", dir.display()))? {
        let entry = entry.with_context(|| format!("failed to list {}", dir.display()))?;
        let Ok(file_name) = entry.file_name().into_string() else {
            continue;
        };
        if !file_name.ends_with(".zoekt") {
            continue;
        }
        let metadata = entry
            .metadata()
            .with_context(|| format!("failed to stat {file_name}"))?;
        shards.insert(file_name, (metadata.ino(), metadata.modified()?));
    }
    Ok(shards)
}

/// The one repo name behind the shard files one `zoekt-git-index` run wrote.
fn written_repo_name(file_names: impl IntoIterator<Item = String>) -> anyhow::Result<String> {
    let mut names = BTreeSet::new();
    for file_name in file_names {
        let name = repo_name_from_shard(&file_name).with_context(|| {
            format!(
                "cannot recover the repo name from shard {file_name}; zoekt shortens names \
                 longer than 200 escaped bytes, so set a shorter `git config zoekt.name`"
            )
        })?;
        names.insert(name);
    }
    let mut names = names.into_iter();
    match (names.next(), names.next()) {
        (Some(name), None) => Ok(name),
        (None, _) => bail!("zoekt-git-index wrote no shard"),
        (Some(first), Some(second)) => {
            bail!("zoekt-git-index wrote shards for both {first} and {second}")
        }
    }
}

/// zoekt names a shard `<query-escaped repo name>_v<format>.<number>.zoekt`,
/// cutting escaped names over 200 bytes and appending 8 hash digits.
fn repo_name_from_shard(file_name: &str) -> Option<String> {
    let stem = file_name.strip_suffix(".zoekt")?;
    let (escaped, version) = stem.rsplit_once("_v")?;
    let (format, number) = version.split_once('.')?;
    let is_number = |value: &str| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit());
    if !is_number(format) || !is_number(number) || escaped.len() > 200 {
        return None;
    }
    query_unescape(escaped)
}

/// Reverses Go's `url.QueryEscape`.
fn query_unescape(escaped: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(escaped.len());
    let mut input = escaped.bytes();
    while let Some(byte) = input.next() {
        bytes.push(match byte {
            b'+' => b' ',
            b'%' => {
                let high = char::from(input.next()?).to_digit(16)?;
                let low = char::from(input.next()?).to_digit(16)?;
                u8::try_from(high * 16 + low).ok()?
            }
            byte => byte,
        });
    }
    String::from_utf8(bytes).ok()
}

/// zoekt's `SearchOptions::SetDefaults` limits, which the CLI searches with.
/// Sending them also keeps the JSON API from substituting early-stopping
/// limits that change which files rank first.
const SHARD_MAX_MATCH_COUNT: usize = 100_000;
const TOTAL_MAX_MATCH_COUNT: usize = 10 * SHARD_MAX_MATCH_COUNT;
const SERVER_CONNECT_TIMEOUT: Duration = Duration::from_millis(250);
/// Longer than the server's own 20 s search timeout.
const SERVER_IO_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_SERVER_RESPONSE_BYTES: u64 = 64 << 20;

/// Searches the resident `zoekt-webserver` when it serves exactly the index on
/// disk, and the zoekt CLI otherwise; both return the same ranked results.
/// `repo_filter` is the name zoekt indexed the repo under, as recorded in
/// [`ZoektReindexStats::repo_names`].
pub fn search(
    config: &SearchConfig,
    zoekt_bin: &str,
    query: &str,
    repo_filter: Option<&str>,
    path_filter: Option<&str>,
    limit: usize,
) -> anyhow::Result<Vec<ZoektMatch>> {
    if !config.index_exists()? {
        bail!(
            "Zoekt index not found at {}; run `flow search reindex` first",
            config.zoekt_index_dir.display()
        );
    }

    let query = scoped_query(query, repo_filter, path_filter);
    match search_server(config, &query, limit) {
        Ok(Some(files)) => return collect_matches(files.into_iter().map(Ok), limit),
        Ok(None) => {
            tracing::debug!(
                "zoekt-webserver is not serving the current index; using the zoekt CLI"
            );
        }
        Err(error) => {
            tracing::debug!(error = %format!("{error:#}"), "zoekt-webserver unavailable; using the zoekt CLI");
        }
    }

    let index_dir = config.zoekt_index_dir.display().to_string();
    let output = Command::new(zoekt_bin)
        .args(["-jsonl", "-index_dir", &index_dir, "--", &query])
        .output()
        .with_context(|| format!("failed to run {}", zoekt_bin))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        bail!("zoekt search failed: {stderr}");
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let files = stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .with_context(|| format!("failed to parse zoekt result line: {line}"))
        });
    collect_matches(files, limit)
}

/// Scopes `query` with zoekt's own repo and file filters, so neither backend
/// spends its match budget on files flow would drop.
fn scoped_query(query: &str, repo_filter: Option<&str>, path_filter: Option<&str>) -> String {
    if repo_filter.is_none() && path_filter.is_none() {
        return query.to_owned();
    }
    let mut scoped = format!("({query})");
    if let Some(repo) = repo_filter {
        let _ = write!(scoped, " repo:^{}$", query_regex_literal(repo));
    }
    if let Some(path) = path_filter {
        // A lowercase pattern is case-insensitive under zoekt's default case:auto.
        let _ = write!(
            scoped,
            " file:{}",
            query_regex_literal(&path.to_lowercase())
        );
    }
    scoped
}

/// Escapes `text` as a regex literal that survives zoekt's query tokenizer,
/// which keeps `\` escapes, ends a token at whitespace and opens a string at `"`.
fn query_regex_literal(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii_punctuation() {
            escaped.push('\\');
            escaped.push(c);
        } else if c.is_whitespace() || c.is_control() {
            let _ = write!(escaped, "\\x{{{:x}}}", u32::from(c));
        } else {
            escaped.push(c);
        }
    }
    escaped
}

fn collect_matches(
    files: impl IntoIterator<Item = anyhow::Result<ZoektFileMatch>>,
    limit: usize,
) -> anyhow::Result<Vec<ZoektMatch>> {
    let mut matches = Vec::new();
    for file_match in files {
        let file_match = file_match?;
        for line_match in file_match.line_matches {
            if matches.len() >= limit {
                break;
            }

            let is_path_match = line_match.file_name || line_match.line_number == 0;
            let snippet = if is_path_match {
                file_match.file_name.clone()
            } else {
                decode_snippet(&line_match.line)?
            };
            matches.push(ZoektMatch {
                repo: file_match.repository.clone(),
                path: file_match.file_name.clone(),
                line: (!is_path_match).then_some(line_match.line_number),
                snippet: snippet.trim().to_owned(),
                is_path_match,
            });
        }

        if matches.len() >= limit {
            break;
        }
    }
    Ok(matches)
}

/// `Ok(None)` when the server does not hold exactly the index on disk, as
/// for tens of seconds after a reindex swaps the directory under it.
fn search_server(
    config: &SearchConfig,
    query: &str,
    limit: usize,
) -> anyhow::Result<Option<Vec<ZoektFileMatch>>> {
    let contents_path = config.zoekt_index_dir.join(INDEX_CONTENTS_FILE);
    let contents = fs::read(&contents_path)
        .with_context(|| format!("failed to read {}", contents_path.display()))?;
    let expected: IndexContents = serde_json::from_slice(&contents)
        .with_context(|| format!("failed to parse {}", contents_path.display()))?;
    let listen = config.zoekt_listen.as_str();
    if served_contents(listen)? != expected {
        return Ok(None);
    }
    let request = serde_json::json!({
        "Q": query,
        "Opts": {
            "MaxDocDisplayCount": limit,
            "ShardMaxMatchCount": SHARD_MAX_MATCH_COUNT,
            "TotalMaxMatchCount": TOTAL_MAX_MATCH_COUNT,
        },
    });
    let response = post_json(listen, "/api/search", &serde_json::to_vec(&request)?)?;
    let response: ServerSearchResponse =
        serde_json::from_slice(&response).context("failed to parse zoekt-webserver results")?;
    // A reload that began during the search could have mixed two indexes.
    if served_contents(listen)? != expected {
        return Ok(None);
    }
    Ok(Some(response.result.files.unwrap_or_default()))
}

fn served_contents(listen: &str) -> anyhow::Result<IndexContents> {
    let response = post_json(listen, "/api/list", br#"{"Q":""}"#)?;
    let response: ServerListResponse =
        serde_json::from_slice(&response).context("failed to parse zoekt-webserver repo list")?;
    Ok(response
        .list
        .repos
        .unwrap_or_default()
        .into_iter()
        .map(|entry| {
            let version = entry
                .repository
                .branches
                .unwrap_or_default()
                .into_iter()
                .find(|branch| branch.name == "HEAD")
                .map(|branch| branch.version)
                .unwrap_or_default();
            let shards = entry.stats.shards;
            (entry.repository.name, IndexedRepo { version, shards })
        })
        .collect())
}

/// One HTTP/1.1 request on its own connection, returning the body of a 200
/// response.
fn post_json(listen: &str, path: &str, body: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut stream = connect(listen)?;
    stream.set_read_timeout(Some(SERVER_IO_TIMEOUT))?;
    stream.set_write_timeout(Some(SERVER_IO_TIMEOUT))?;
    let mut request = format!(
        "POST {path} HTTP/1.1\r\nHost: {listen}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    request.extend_from_slice(body);
    stream.write_all(&request)?;

    let mut response = Vec::new();
    (&stream)
        .take(MAX_SERVER_RESPONSE_BYTES + 1)
        .read_to_end(&mut response)?;
    if response.len() as u64 > MAX_SERVER_RESPONSE_BYTES {
        bail!("zoekt-webserver response exceeds {MAX_SERVER_RESPONSE_BYTES} bytes");
    }
    response_body(&response)
}

fn connect(listen: &str) -> anyhow::Result<TcpStream> {
    let mut last_error = None;
    for address in listen.to_socket_addrs()? {
        match TcpStream::connect_timeout(&address, SERVER_CONNECT_TIMEOUT) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
    }
    match last_error {
        Some(error) => Err(error).with_context(|| format!("failed to connect to {listen}")),
        None => bail!("{listen} resolves to no address"),
    }
}

/// The body of a complete HTTP/1.1 response read up to the closed connection.
fn response_body(response: &[u8]) -> anyhow::Result<Vec<u8>> {
    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .context("incomplete HTTP response")?;
    let head = std::str::from_utf8(&response[..header_end]).context("non-UTF-8 HTTP header")?;
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .context("malformed HTTP status line")?;
    let chunked = lines.any(|line| {
        line.split_once(':').is_some_and(|(name, value)| {
            name.trim().eq_ignore_ascii_case("transfer-encoding")
                && value.trim().eq_ignore_ascii_case("chunked")
        })
    });
    let body = &response[header_end + 4..];
    let body = if chunked {
        decode_chunked(body)?
    } else {
        body.to_vec()
    };
    if status != 200 {
        bail!(
            "zoekt-webserver answered {status}: {}",
            String::from_utf8_lossy(&body).trim()
        );
    }
    Ok(body)
}

fn decode_chunked(mut body: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut decoded = Vec::new();
    loop {
        let line_end = body
            .windows(2)
            .position(|window| window == b"\r\n")
            .context("truncated chunked body")?;
        let size_line = std::str::from_utf8(&body[..line_end]).context("malformed chunk size")?;
        let size_field = size_line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size_field, 16).context("malformed chunk size")?;
        body = &body[line_end + 2..];
        if size == 0 {
            return Ok(decoded);
        }
        let chunk = body.get(..size).context("truncated chunked body")?;
        decoded.extend_from_slice(chunk);
        body = body
            .get(size..)
            .and_then(|rest| rest.strip_prefix(b"\r\n"))
            .context("truncated chunked body")?;
    }
}

fn decode_snippet(value: &str) -> anyhow::Result<String> {
    let bytes = BASE64_STANDARD
        .decode(value)
        .with_context(|| format!("failed to decode zoekt snippet {value}"))?;
    Ok(String::from_utf8_lossy(&bytes).to_string())
}

#[derive(Clone, Debug, Deserialize)]
struct ZoektFileMatch {
    #[serde(rename = "FileName")]
    file_name: String,
    #[serde(rename = "Repository")]
    repository: String,
    #[serde(rename = "LineMatches", default)]
    line_matches: Vec<ZoektLineMatch>,
}

#[derive(Clone, Debug, Deserialize)]
struct ZoektLineMatch {
    #[serde(rename = "Line")]
    line: String,
    #[serde(rename = "LineNumber")]
    line_number: u32,
    #[serde(rename = "FileName")]
    file_name: bool,
}

#[derive(Debug, Deserialize)]
struct ServerSearchResponse {
    #[serde(rename = "Result")]
    result: ServerSearchResult,
}

#[derive(Debug, Deserialize)]
struct ServerSearchResult {
    #[serde(rename = "Files", default)]
    files: Option<Vec<ZoektFileMatch>>,
}

#[derive(Debug, Deserialize)]
struct ServerListResponse {
    #[serde(rename = "List")]
    list: ServerRepoList,
}

#[derive(Debug, Deserialize)]
struct ServerRepoList {
    #[serde(rename = "Repos", default)]
    repos: Option<Vec<ServerRepoListEntry>>,
}

#[derive(Debug, Deserialize)]
struct ServerRepoListEntry {
    #[serde(rename = "Repository")]
    repository: ServerRepository,
    #[serde(rename = "Stats")]
    stats: ServerRepoStats,
}

#[derive(Debug, Deserialize)]
struct ServerRepository {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Branches", default)]
    branches: Option<Vec<ServerBranch>>,
}

#[derive(Debug, Deserialize)]
struct ServerBranch {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Version")]
    version: String,
}

#[derive(Debug, Deserialize)]
struct ServerRepoStats {
    #[serde(rename = "Shards")]
    shards: usize,
}

#[cfg(test)]
mod tests {
    use super::{ZoektFileMatch, decode_snippet, search, written_repo_name};
    use crate::search::config::SearchConfig;
    use std::fs;
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};
    use std::net::TcpListener;
    use std::path::Path;
    use std::thread::JoinHandle;
    use tempfile::TempDir;

    const MISSING_CLI: &str = "/nonexistent/zoekt";

    fn config_with_index(state_dir: &Path, listen: String) -> SearchConfig {
        let index_dir = state_dir.join("zoekt/index");
        fs::create_dir_all(&index_dir).expect("index dir");
        fs::write(index_dir.join("example.com%2Fdemo_v16.00000.zoekt"), b"").expect("shard");
        fs::write(
            index_dir.join("flow-index.json"),
            r#"{"example.com/demo":{"version":"abc123","shards":1}}"#,
        )
        .expect("index contents");
        SearchConfig {
            roots: Vec::new(),
            state_dir: state_dir.to_path_buf(),
            zoekt_dir: state_dir.join("zoekt"),
            zoekt_index_dir: index_dir,
            metadata_dir: state_dir.join("metadata"),
            metadata_db_path: state_dir.join("metadata/commits.sqlite"),
            repos_manifest_path: state_dir.join("metadata/repos.json"),
            state_path: state_dir.join("state.json"),
            reindex_lock_path: state_dir.join("reindex.lock"),
            zoekt_listen: listen,
            excluded_dir_names: Vec::new(),
        }
    }

    fn list_body(version: &str) -> String {
        format!(
            r#"{{"List":{{"Repos":[{{"Repository":{{"Name":"example.com/demo","Branches":[{{"Name":"HEAD","Version":"{version}"}}]}},"Stats":{{"Shards":1}}}}]}}}}"#
        )
    }

    /// Serves `connections` requests like zoekt-webserver -rpc and returns the
    /// request bodies it received. Search results come back chunked, as Go
    /// sends a large body.
    fn fake_server(list: String, connections: usize) -> (String, JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address").to_string();
        let handle = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for stream in listener.incoming().take(connections) {
                let mut stream = stream.expect("accept");
                let mut reader = BufReader::new(&stream);
                let mut request_line = String::new();
                reader.read_line(&mut request_line).expect("request line");
                let mut content_length = 0;
                loop {
                    let mut header = String::new();
                    reader.read_line(&mut header).expect("header");
                    if header == "\r\n" {
                        break;
                    }
                    if let Some(value) = header.strip_prefix("Content-Length:") {
                        content_length = value.trim().parse().expect("length");
                    }
                }
                let mut body = vec![0; content_length];
                reader.read_exact(&mut body).expect("body");
                requests.push(String::from_utf8(body).expect("utf8 body"));
                let response = if request_line.starts_with("POST /api/list ") {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{list}",
                        list.len()
                    )
                } else {
                    let result = r#"{"Result":{"Files":[{"FileName":"src/main.rs","Repository":"example.com/demo","LineMatches":[{"Line":"Zm4gaGVsbG8oKSB7fQ==","LineNumber":3,"FileName":false},{"Line":"Zm4gd29ybGQoKSB7fQ==","LineNumber":7,"FileName":false}]}]}}"#;
                    let (head, tail) = result.split_at(20);
                    format!(
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{head}\r\n{:x}\r\n{tail}\r\n0\r\n\r\n",
                        head.len(),
                        tail.len()
                    )
                };
                stream.write_all(response.as_bytes()).expect("respond");
            }
            requests
        });
        (address, handle)
    }

    #[test]
    fn search_uses_a_server_holding_the_current_index() {
        let sandbox = TempDir::new().expect("tempdir");
        let (address, server) = fake_server(list_body("abc123"), 3);
        let config = config_with_index(sandbox.path(), address);

        // The CLI does not exist, so any result must come from the server.
        let matches = search(
            &config,
            MISSING_CLI,
            "fn",
            Some("example.com/demo"),
            Some("SRC"),
            1,
        )
        .expect("server search");
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].repo, "example.com/demo");
        assert_eq!(matches[0].path, "src/main.rs");
        assert_eq!(matches[0].line, Some(3));
        assert_eq!(matches[0].snippet, "fn hello() {}");

        let requests = server.join().expect("server thread");
        let search_request: serde_json::Value =
            serde_json::from_str(&requests[1]).expect("search request");
        assert_eq!(
            search_request["Q"],
            r"(fn) repo:^example\.com\/demo$ file:src"
        );
        assert_eq!(search_request["Opts"]["MaxDocDisplayCount"], 1);
    }

    #[test]
    fn search_skips_a_server_still_holding_an_older_index() {
        let sandbox = TempDir::new().expect("tempdir");
        let (address, server) = fake_server(list_body("older"), 1);
        let config = config_with_index(sandbox.path(), address);

        let error = search(&config, MISSING_CLI, "fn", None, None, 25)
            .expect_err("falls back to the missing CLI");
        assert!(error.to_string().contains(MISSING_CLI), "{error}");
        server.join().expect("server thread");
    }

    #[test]
    fn decodes_base64_snippets() {
        assert_eq!(
            decode_snippet("aGVsbG8=").expect("snippet decodes"),
            "hello"
        );
    }

    #[test]
    fn parses_jsonl_file_match() {
        let parsed: ZoektFileMatch = serde_json::from_str(
            r#"{"FileName":"src/main.rs","Repository":"dotfiles","LineMatches":[{"Line":"aGVsbG8=","LineNumber":1,"FileName":false}]}"#,
        )
        .expect("json parses");
        assert_eq!(parsed.file_name, "src/main.rs");
        assert_eq!(parsed.repository, "dotfiles");
        assert_eq!(parsed.line_matches.len(), 1);
    }

    #[test]
    fn repo_name_comes_from_the_written_shards() {
        let shards = |names: &[&str]| {
            names
                .iter()
                .map(|name| (*name).to_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            written_repo_name(shards(&[
                "github.com%2Fjmqd%2Fdotfiles_v16.00000.zoekt",
                "github.com%2Fjmqd%2Fdotfiles_v16.00001.zoekt",
            ]))
            .expect("one repo"),
            "github.com/jmqd/dotfiles"
        );
        assert_eq!(
            written_repo_name(shards(&["group%2Fmy+repo_v16.00000.zoekt"])).expect("one repo"),
            "group/my repo"
        );
        assert!(written_repo_name(shards(&[])).is_err());
        assert!(written_repo_name(shards(&["a_v16.00000.zoekt", "b_v16.00000.zoekt"])).is_err());
        // zoekt cut this name and appended a hash, so it cannot be recovered.
        let shortened = format!("{}0123abcd_v16.00000.zoekt", "a".repeat(200));
        assert!(written_repo_name(shards(&[&shortened])).is_err());
    }

    #[test]
    fn path_and_repo_filters_escape_zoekt_query_syntax() {
        assert_eq!(super::scoped_query("a or b", None, None), "a or b");
        assert_eq!(
            super::scoped_query("x", Some("host/my repo(1)\"q"), Some("Dir/A b")),
            r#"(x) repo:^host\/my\x{20}repo\(1\)\"q$ file:dir\/a\x{20}b"#
        );
    }
}
