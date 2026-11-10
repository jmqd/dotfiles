//! Export one Spotify playlist's item metadata as a TSV flat file.
//!
//! Authentication uses the Authorization Code flow with PKCE, so only a
//! client ID is needed. The refresh token is cached under the user's config
//! directory with mode 0600.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use reqwest::blocking::{Client, Response};
use reqwest::{StatusCode, Url};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Result<T, E = Box<dyn Error>> = std::result::Result<T, E>;

const API: &str = "https://api.spotify.com/v1";
const API_ORIGIN: &str = "https://api.spotify.com/";
const AUTHORIZE_URL: &str = "https://accounts.spotify.com/authorize";
const TOKEN_URL: &str = "https://accounts.spotify.com/api/token";
const SCOPES: &str = "playlist-read-private playlist-read-collaborative";
const DEFAULT_PORT: u16 = 8888;
const MAX_RETRIES: u32 = 5;
const MAX_RETRY_WAIT_SECS: u64 = 60;
const CALLBACK_READ_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_REQUEST_LINE_BYTES: u64 = 8192;

const USAGE: &str = "\
usage: spotify-export [options] <playlist>

<playlist> is an exact playlist name from your library, a spotify:playlist:
URI, or an open.spotify.com playlist URL. Writes TSV to stdout by default.

options:
  -o, --output FILE   write TSV to FILE instead of stdout
      --client-id ID  Spotify app client ID (default: $SPOTIFY_CLIENT_ID)
      --port PORT     loopback callback port (default: 8888)
  -h, --help          show this help

Register http://127.0.0.1:<port>/callback as a redirect URI in your
Spotify app. Tokens are cached in $XDG_CONFIG_HOME/spotify-export/.";

struct Args {
    playlist: String,
    output: Option<PathBuf>,
    client_id: String,
    port: u16,
}

fn parse_args() -> Result<Option<Args>> {
    let mut playlist = None;
    let mut output = None;
    let mut client_id = std::env::var("SPOTIFY_CLIENT_ID").ok();
    let mut port = DEFAULT_PORT;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |flag: &str| args.next().ok_or_else(|| format!("{flag} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(None),
            "-o" | "--output" => output = Some(PathBuf::from(value(&arg)?)),
            "--client-id" => client_id = Some(value(&arg)?),
            "--port" => port = value(&arg)?.parse().map_err(|_| "--port must be 1-65535")?,
            flag if flag.starts_with('-') && flag.len() > 1 => {
                return Err(format!("unknown option {flag}").into())
            }
            _ if playlist.is_some() => return Err("expected exactly one playlist".into()),
            _ => playlist = Some(arg),
        }
    }
    let playlist = playlist.ok_or("missing <playlist>")?;
    let client_id = client_id
        .filter(|id| !id.is_empty())
        .ok_or("set SPOTIFY_CLIENT_ID or pass --client-id")?;
    Ok(Some(Args {
        playlist,
        output,
        client_id,
        port,
    }))
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(err) => {
            eprintln!("spotify-export: {err}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("spotify-export: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &Args) -> Result<()> {
    let http = Client::builder()
        .user_agent("spotify-export/0.1")
        .https_only(true)
        .build()?;
    let token = access_token(&http, args)?;
    let api = Api {
        http: &http,
        token: &token,
    };

    let playlist_id = match playlist_id_from_ref(&args.playlist) {
        Some(id) => id,
        None => find_playlist_by_name(&api, &args.playlist)?,
    };

    // Buffer the whole export so a mid-pagination failure never leaves a
    // truncated file or clobbers an earlier good export.
    let mut tsv = Vec::new();
    let count = export(&api, &playlist_id, &mut tsv)?;
    match &args.output {
        Some(path) => write_via_temp_file(path, &tsv)?,
        None => io::stdout().lock().write_all(&tsv)?,
    }
    eprintln!("spotify-export: wrote {count} rows");
    Ok(())
}

/// Write `bytes` to `FILE.tmp`, then rename it over `path`. The temporary
/// name is predictable, so `create_new` (O_EXCL) refuses an existing file or
/// a planted symlink there instead of following and truncating it.
fn write_via_temp_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .map_err(|e| format!("cannot create {}: {e}", tmp.display()))?;
    if let Err(err) = file.write_all(bytes).and_then(|()| fs::rename(&tmp, path)) {
        let _ = fs::remove_file(&tmp);
        return Err(err.into());
    }
    Ok(())
}

// ---------------------------------------------------------------- playlist

#[derive(Deserialize)]
struct Page<T> {
    items: Vec<T>,
    next: Option<String>,
}

#[derive(Deserialize)]
struct SimplePlaylist {
    id: String,
    name: String,
    owner: User,
}

#[derive(Deserialize)]
struct User {
    id: String,
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct PlaylistItem {
    added_at: Option<String>,
    added_by: Option<User>,
    #[serde(default)]
    is_local: bool,
    /// Current field name since the February 2026 API change.
    item: Option<Media>,
    /// Deprecated alias Spotify still sends alongside `item`.
    track: Option<Media>,
}

/// A track or podcast episode; fields absent from either type stay `None`.
#[derive(Deserialize)]
struct Media {
    #[serde(rename = "type")]
    kind: Option<String>,
    name: Option<String>,
    uri: Option<String>,
    duration_ms: Option<u64>,
    explicit: Option<bool>,
    disc_number: Option<u32>,
    track_number: Option<u32>,
    #[serde(default)]
    artists: Vec<Named>,
    album: Option<Album>,
    show: Option<Named>,
    release_date: Option<String>,
    external_ids: Option<ExternalIds>,
    external_urls: Option<ExternalUrls>,
}

#[derive(Deserialize)]
struct Named {
    name: String,
}

#[derive(Deserialize)]
struct Album {
    name: Option<String>,
    release_date: Option<String>,
    #[serde(default)]
    artists: Vec<Named>,
}

#[derive(Deserialize)]
struct ExternalIds {
    isrc: Option<String>,
}

#[derive(Deserialize)]
struct ExternalUrls {
    spotify: Option<String>,
}

/// Accept `spotify:playlist:ID` and `https://open.spotify.com/playlist/ID?...`.
fn playlist_id_from_ref(arg: &str) -> Option<String> {
    let id = if let Some(id) = arg.strip_prefix("spotify:playlist:") {
        id.to_owned()
    } else {
        let url = Url::parse(arg).ok()?;
        if url.host_str()? != "open.spotify.com" {
            return None;
        }
        let mut segments = url.path_segments()?.filter(|s| !s.is_empty());
        // Localized links look like /intl-de/playlist/ID.
        segments.find(|s| *s == "playlist")?;
        segments.next()?.to_owned()
    };
    let valid = !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric());
    valid.then_some(id)
}

fn find_playlist_by_name(api: &Api, name: &str) -> Result<String> {
    let mut matches = Vec::new();
    let mut url = format!("{API}/me/playlists?limit=50");
    loop {
        let page: Page<Option<SimplePlaylist>> = api.get(&url)?;
        matches.extend(page.items.into_iter().flatten().filter(|p| p.name == name));
        match next_page_url(page.next)? {
            Some(next) => url = next,
            None => break,
        }
    }
    match matches.len() {
        0 => Err(format!("no playlist named {name:?} in your library").into()),
        1 => Ok(matches.remove(0).id),
        _ => {
            let mut msg = format!(
                "{} playlists are named {name:?}; pass one as a URI:",
                matches.len()
            );
            for p in &matches {
                let owner = p.owner.display_name.as_deref().unwrap_or(&p.owner.id);
                msg.push_str(&format!("\n  spotify:playlist:{}  (owner: {owner})", p.id));
            }
            Err(msg.into())
        }
    }
}

const COLUMNS: [&str; 17] = [
    "position",
    "type",
    "name",
    "artists",
    "album",
    "album_artists",
    "release_date",
    "duration_ms",
    "explicit",
    "disc_number",
    "track_number",
    "isrc",
    "is_local",
    "added_at",
    "added_by",
    "uri",
    "url",
];

fn export(api: &Api, playlist_id: &str, out: &mut dyn Write) -> Result<usize> {
    writeln!(out, "{}", COLUMNS.join("\t"))?;
    let mut url = format!("{API}/playlists/{playlist_id}/items?limit=50");
    let mut position = 0;
    loop {
        let page: Page<PlaylistItem> = api.get(&url)?;
        for entry in page.items {
            position += 1;
            write_row(out, position, entry)?;
        }
        match next_page_url(page.next)? {
            Some(next) => url = next,
            None => break,
        }
    }
    Ok(position)
}

fn write_row(out: &mut dyn Write, position: usize, entry: PlaylistItem) -> Result<()> {
    let media = entry.item.or(entry.track);
    let m = media.as_ref();
    let joined = |names: &[Named]| {
        names
            .iter()
            .map(|n| n.name.as_str())
            .collect::<Vec<_>>()
            .join("; ")
    };
    let opt = |v: Option<String>| v.unwrap_or_default();
    let num = |v: Option<u64>| v.map(|n| n.to_string()).unwrap_or_default();

    let album = m.and_then(|m| m.album.as_ref());
    // Episodes carry their show where tracks carry an album.
    let collection = album
        .and_then(|a| a.name.clone())
        .or_else(|| m.and_then(|m| m.show.as_ref()).map(|s| s.name.clone()));
    let release_date = album
        .and_then(|a| a.release_date.clone())
        .or_else(|| m.and_then(|m| m.release_date.clone()));

    let fields = [
        position.to_string(),
        opt(m.and_then(|m| m.kind.clone())),
        opt(m.and_then(|m| m.name.clone())),
        m.map(|m| joined(&m.artists)).unwrap_or_default(),
        opt(collection),
        album.map(|a| joined(&a.artists)).unwrap_or_default(),
        opt(release_date),
        num(m.and_then(|m| m.duration_ms)),
        opt(m.and_then(|m| m.explicit).map(|b| b.to_string())),
        num(m.and_then(|m| m.disc_number).map(u64::from)),
        num(m.and_then(|m| m.track_number).map(u64::from)),
        opt(m
            .and_then(|m| m.external_ids.as_ref())
            .and_then(|e| e.isrc.clone())),
        entry.is_local.to_string(),
        opt(entry.added_at),
        opt(entry.added_by.map(|u| u.display_name.unwrap_or(u.id))),
        opt(m.and_then(|m| m.uri.clone())),
        opt(m
            .and_then(|m| m.external_urls.as_ref())
            .and_then(|u| u.spotify.clone())),
    ];
    let mut line = String::new();
    for (i, field) in fields.iter().enumerate() {
        if i > 0 {
            line.push('\t');
        }
        line.extend(field.chars().map(|c| {
            if matches!(c, '\t' | '\n' | '\r') {
                ' '
            } else {
                c
            }
        }));
    }
    writeln!(out, "{line}")?;
    Ok(())
}

// --------------------------------------------------------------------- API

struct Api<'a> {
    http: &'a Client,
    token: &'a str,
}

impl Api<'_> {
    fn get<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        let resp = send_with_retry(|| self.http.get(url).bearer_auth(self.token).send())?;
        Ok(resp.json()?)
    }
}

/// Check a response's pagination link before following it. `Api::get` sends
/// the bearer token to that URL, so only the API origin over HTTPS is accepted.
fn next_page_url(next: Option<String>) -> Result<Option<String>> {
    match next {
        Some(url) if url.starts_with(API_ORIGIN) => Ok(Some(url)),
        Some(url) => Err(format!("refusing pagination URL outside {API_ORIGIN}: {url}").into()),
        None => Ok(None),
    }
}

/// Retry rate limits (honoring a short Retry-After) and transient 5xx, a bounded number of times.
fn send_with_retry(send: impl Fn() -> reqwest::Result<Response>) -> Result<Response> {
    for attempt in 0..=MAX_RETRIES {
        let resp = send()?;
        let status = resp.status();
        if status.is_success() {
            return Ok(resp);
        }
        let retryable = status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error();
        if !retryable || attempt == MAX_RETRIES {
            let url = resp.url().clone();
            let body = resp.text().unwrap_or_default();
            let hint = if status == StatusCode::FORBIDDEN {
                "\n(development-mode apps can only read playlists you own or collaborate on)"
            } else {
                ""
            };
            return Err(format!("{status} from {url}: {}{hint}", body.trim()).into());
        }
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok());
        let wait = retry_wait(retry_after, attempt)
            .map_err(|e| format!("{status} from {}: {e}", resp.url()))?;
        eprintln!("spotify-export: {status}, retrying in {wait}s");
        sleep(Duration::from_secs(wait));
    }
    unreachable!("loop returns on the final attempt")
}

/// Seconds to wait before retrying after failed attempt `attempt`: the
/// server's Retry-After seconds if given, else exponential backoff. Spotify
/// can ask for hours, so a wait above `MAX_RETRY_WAIT_SECS` fails the run.
fn retry_wait(retry_after: Option<&str>, attempt: u32) -> Result<u64, String> {
    let wait = retry_after
        .and_then(|v| v.parse().ok())
        .unwrap_or(1u64 << attempt);
    if wait > MAX_RETRY_WAIT_SECS {
        return Err(format!(
            "rate limited for {wait}s (over the {MAX_RETRY_WAIT_SECS}s limit); try again later"
        ));
    }
    Ok(wait)
}

// -------------------------------------------------------------------- auth

#[derive(Serialize, Deserialize)]
struct StoredToken {
    client_id: String,
    access_token: String,
    refresh_token: String,
    expires_at: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    refresh_token: Option<String>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn token_path() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?).join(".config"),
    };
    Ok(base.join("spotify-export").join("token.json"))
}

fn access_token(http: &Client, args: &Args) -> Result<String> {
    let path = token_path()?;
    let cached = fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<StoredToken>(&bytes).ok())
        .filter(|t| t.client_id == args.client_id);

    if let Some(stored) = cached {
        if stored.expires_at > now() + 60 {
            return Ok(stored.access_token);
        }
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", stored.refresh_token.as_str()),
            ("client_id", args.client_id.as_str()),
        ];
        match request_token(http, &form) {
            Ok(resp) => {
                return save_token(&path, &args.client_id, resp, Some(stored.refresh_token))
            }
            Err(err) => eprintln!("spotify-export: token refresh failed ({err}); re-authorizing"),
        }
    }
    let resp = authorize_interactively(http, args)?;
    save_token(&path, &args.client_id, resp, None)
}

fn request_token(http: &Client, form: &[(&str, &str)]) -> Result<TokenResponse> {
    Ok(send_with_retry(|| http.post(TOKEN_URL).form(form).send())?.json()?)
}

fn save_token(
    path: &Path,
    client_id: &str,
    resp: TokenResponse,
    old_refresh: Option<String>,
) -> Result<String> {
    let refresh_token = resp
        .refresh_token
        .or(old_refresh)
        .ok_or("token response had no refresh_token")?;
    let stored = StoredToken {
        client_id: client_id.to_owned(),
        access_token: resp.access_token,
        refresh_token,
        expires_at: now() + resp.expires_in,
    };
    let dir = path.parent().ok_or("token path has no parent")?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join("token.json.tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
        let mut file = opts.open(&tmp)?;
        file.write_all(&serde_json::to_vec(&stored)?)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(stored.access_token)
}

fn random_urlsafe(bytes: usize) -> Result<String> {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).map_err(|e| format!("random source failed: {e}"))?;
    Ok(URL_SAFE_NO_PAD.encode(buf))
}

/// RFC 7636 S256 code challenge for a PKCE verifier.
fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn authorize_interactively(http: &Client, args: &Args) -> Result<TokenResponse> {
    let redirect_uri = format!("http://127.0.0.1:{}/callback", args.port);
    // Bind before opening the browser so the redirect cannot race the listener.
    let listener = TcpListener::bind(("127.0.0.1", args.port))
        .map_err(|e| format!("cannot listen on 127.0.0.1:{}: {e}", args.port))?;

    let verifier = random_urlsafe(64)?;
    let challenge = pkce_challenge(&verifier);
    let state = random_urlsafe(16)?;
    let url = Url::parse_with_params(
        AUTHORIZE_URL,
        [
            ("client_id", args.client_id.as_str()),
            ("response_type", "code"),
            ("redirect_uri", redirect_uri.as_str()),
            ("scope", SCOPES),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge.as_str()),
            ("state", state.as_str()),
        ],
    )?;

    eprintln!("spotify-export: authorize in your browser:\n  {url}");
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let _ = Command::new(opener).arg(url.as_str()).status();

    let code = wait_for_code(&listener, &state)?;
    let form = [
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("redirect_uri", redirect_uri.as_str()),
        ("client_id", args.client_id.as_str()),
        ("code_verifier", verifier.as_str()),
    ];
    request_token(http, &form)
}

/// Serve callback requests until one carries our state; ignore strays like /favicon.ico.
fn wait_for_code(listener: &TcpListener, state: &str) -> Result<String> {
    for _ in 0..20 {
        let (mut stream, _) = listener.accept()?;
        let request_line = match read_request_line(&stream, CALLBACK_READ_TIMEOUT) {
            Ok(line) => line,
            Err(err) => {
                eprintln!("spotify-export: ignoring callback connection: {err}");
                continue;
            }
        };
        let target = request_line.split_whitespace().nth(1).unwrap_or("/");
        let url = Url::parse(&format!("http://127.0.0.1{target}"))?;
        if url.path() != "/callback" {
            let _ = stream.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            continue;
        }
        let param = |key: &str| {
            url.query_pairs()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.into_owned())
        };
        let (outcome, message) = if param("state").as_deref() != Some(state) {
            (
                Err("authorization callback had a mismatched state".to_owned()),
                "State mismatch.",
            )
        } else if let Some(err) = param("error") {
            (
                Err(format!("authorization denied: {err}")),
                "Authorization failed.",
            )
        } else if let Some(code) = param("code") {
            (Ok(code), "Authorized. You can close this tab.")
        } else {
            (
                Err("authorization callback had no code".to_owned()),
                "Missing code.",
            )
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{message}",
            message.len()
        );
        let _ = stream.write_all(response.as_bytes());
        return outcome.map_err(Into::into);
    }
    Err("too many unrelated requests on the callback port".into())
}

/// Read one HTTP request line. Any local process can connect to the callback
/// port, so bound the wait and the size instead of trusting the client.
fn read_request_line(stream: &TcpStream, timeout: Duration) -> io::Result<String> {
    stream.set_read_timeout(Some(timeout))?;
    let mut line = String::new();
    BufReader::new(stream.take(MAX_REQUEST_LINE_BYTES)).read_line(&mut line)?;
    if !line.ends_with('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("no request line within {MAX_REQUEST_LINE_BYTES} bytes"),
        ));
    }
    Ok(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc7636_appendix_b() {
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn pagination_follows_only_the_api_origin() {
        let next = |url: &str| next_page_url(Some(url.to_owned()));
        let ok = "https://api.spotify.com/v1/me/playlists?offset=50&limit=50";
        assert_eq!(next(ok).unwrap().as_deref(), Some(ok));
        assert_eq!(next_page_url(None).unwrap(), None);
        for bad in [
            "http://api.spotify.com/v1/me/playlists?offset=50",
            "https://example.com/v1/me/playlists",
            "https://api.spotify.com.evil.example/v1/me/playlists",
            "https://api.spotify.com@evil.example/v1",
            "https://accounts.spotify.com/v1",
        ] {
            assert!(next(bad).is_err(), "{bad} was accepted");
        }
    }

    #[test]
    fn playlist_refs() {
        let id = Some("37i9dQZF1DXcBWIGoYBM5M".to_owned());
        assert_eq!(
            playlist_id_from_ref("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
            id
        );
        assert_eq!(
            playlist_id_from_ref("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc"),
            id
        );
        assert_eq!(
            playlist_id_from_ref(
                "https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M"
            ),
            id
        );
        assert_eq!(playlist_id_from_ref("Road Trip"), None);
        assert_eq!(
            playlist_id_from_ref("https://example.com/playlist/abc"),
            None
        );
        assert_eq!(playlist_id_from_ref("spotify:playlist:../me"), None);
    }

    #[test]
    fn row_prefers_item_over_deprecated_track_and_flattens_whitespace() {
        let entry: PlaylistItem = serde_json::from_value(serde_json::json!({
            "added_at": "2026-01-02T03:04:05Z",
            "added_by": {"id": "u1", "display_name": null},
            "is_local": false,
            "item": {
                "type": "track", "name": "New\tName", "uri": "spotify:track:1",
                "duration_ms": 1000, "explicit": true, "disc_number": 1, "track_number": 2,
                "artists": [{"name": "A"}, {"name": "B"}],
                "album": {"name": "Al", "release_date": "2020", "artists": [{"name": "A"}]},
                "external_ids": {"isrc": "X1"},
                "external_urls": {"spotify": "https://open.spotify.com/track/1"}
            },
            "track": {"type": "track", "name": "Old"}
        }))
        .unwrap();
        let mut out = Vec::new();
        write_row(&mut out, 7, entry).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "7\ttrack\tNew Name\tA; B\tAl\tA\t2020\t1000\ttrue\t1\t2\tX1\tfalse\t\
             2026-01-02T03:04:05Z\tu1\tspotify:track:1\thttps://open.spotify.com/track/1\n"
        );
    }

    #[test]
    fn row_for_removed_track_keeps_column_count() {
        let entry: PlaylistItem =
            serde_json::from_value(serde_json::json!({"item": null, "track": null})).unwrap();
        let mut out = Vec::new();
        write_row(&mut out, 1, entry).unwrap();
        assert_eq!(
            String::from_utf8(out)
                .unwrap()
                .trim_end_matches('\n')
                .split('\t')
                .count(),
            COLUMNS.len()
        );
    }

    /// A fresh directory under the system temp dir, unique to this process and test.
    fn scratch_dir(test: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("spotify-export-{}-{test}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn output_write_replaces_file_and_leaves_no_temp() {
        let dir = scratch_dir("output-write");
        let out = dir.join("list.tsv");
        fs::write(&out, "old").unwrap();
        write_via_temp_file(&out, b"new\n").unwrap();
        assert_eq!(fs::read(&out).unwrap(), b"new\n");
        assert!(!dir.join("list.tsv.tmp").exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn output_write_refuses_symlink_at_temp_name() {
        let dir = scratch_dir("output-symlink");
        let victim = dir.join("victim");
        fs::write(&victim, "precious").unwrap();
        let out = dir.join("list.tsv");
        std::os::unix::fs::symlink(&victim, dir.join("list.tsv.tmp")).unwrap();
        assert!(write_via_temp_file(&out, b"tsv\n").is_err());
        assert_eq!(fs::read(&victim).unwrap(), b"precious");
        assert!(!out.exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn retry_waits_briefly_and_refuses_long_retry_after() {
        assert_eq!(retry_wait(Some("60"), 0), Ok(60));
        assert_eq!(retry_wait(None, 3), Ok(8));
        assert_eq!(retry_wait(Some("soon"), 2), Ok(4));
        assert!(retry_wait(Some("61"), 0).is_err());
        let err = retry_wait(Some("3600"), 0).unwrap_err();
        assert!(err.contains("3600s"), "{err}");
    }

    /// A connected loopback pair: (client, accepted server side).
    fn loopback_pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        (client, server)
    }

    #[test]
    fn callback_reader_returns_the_request_line() {
        let (mut client, server) = loopback_pair();
        client
            .write_all(b"GET /callback?code=c HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        let line = read_request_line(&server, Duration::from_secs(10)).unwrap();
        assert_eq!(line, "GET /callback?code=c HTTP/1.1\r\n");
    }

    #[test]
    fn callback_reader_refuses_an_overlong_request_line() {
        let (mut client, server) = loopback_pair();
        let line = format!("GET /callback?{} HTTP/1.1\r\n", "a".repeat(9000));
        client.write_all(line.as_bytes()).unwrap();
        let err = read_request_line(&server, Duration::from_secs(10)).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn callback_reader_times_out_on_a_silent_client() {
        let (_client, server) = loopback_pair();
        let start = std::time::Instant::now();
        let err = read_request_line(&server, Duration::from_millis(200)).unwrap_err();
        assert!(
            matches!(
                err.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ),
            "{err}"
        );
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn callback_skips_a_bad_connection_and_takes_the_next() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        let mut flood = TcpStream::connect(addr).unwrap();
        flood.write_all("a".repeat(9000).as_bytes()).unwrap();
        let mut browser = TcpStream::connect(addr).unwrap();
        browser
            .write_all(b"GET /callback?state=s&code=c HTTP/1.1\r\n\r\n")
            .unwrap();
        assert_eq!(wait_for_code(&listener, "s").unwrap(), "c");
    }
}
