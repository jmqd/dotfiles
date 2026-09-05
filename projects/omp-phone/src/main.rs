mod config;
mod push;
mod sessions;

use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    middleware::{self, Next},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use config::{Config, Result};
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::json;
use sessions::{CommandResult, Pending, Registry, Session};
use std::{
    collections::HashMap,
    convert::Infallible,
    net::Ipv4Addr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, mpsc, oneshot, watch, Semaphore};
use tokio_util::codec::{Framed, LinesCodec};

const COOKIE: &str = "omp_phone";
const COOKIE_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const ACK_TIMEOUT: Duration = Duration::from_secs(15);

struct App {
    config: Config,
    token: String,
    logins: Mutex<HashMap<String, Instant>>,
    registry: Mutex<Registry>,
    events: broadcast::Sender<()>,
    shutdown: watch::Sender<bool>,
    next_connection: AtomicU64,
    sockets: Arc<Semaphore>,
    push: Arc<push::Push>,
    turns: mpsc::Sender<push::Turn>,
}

struct ApiError(StatusCode, String);
impl ApiError {
    fn new(status: StatusCode, message: &str) -> Self {
        Self(status, message.into())
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}
type ApiResult<T, E = ApiError> = std::result::Result<T, E>;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("omp-phone: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!(
            r#"omp-phone [serve|pair]

serve (default): bind HTTP to 127.0.0.1 and extension control to a private Unix socket.
pair: print the configured URL with a secret pairing fragment. Treat it as a password.

Environment:
  OMP_PHONE_PORT                Local port (default 8787)
  OMP_PHONE_PUBLIC_URL          Exact Tailscale HTTPS origin; unset for localhost development
  OMP_PHONE_TAILNET_USERS       Comma-separated exact logins; required for HTTPS
  OMP_PHONE_TAILNET_CAPABILITY  Member-only app capability with access=true; required for HTTPS
  OMP_PHONE_HOSTNAME            Display name for this machine
  OMP_PHONE_STATE_DIR           Private runtime directory
                               (default $XDG_STATE_HOME/omp-phone or ~/.local/state/omp-phone)

HTTPS requires Tailscale Serve 1.92+ forwarding the configured app capability.
Grant that capability only to direct tailnet members. Never use public Funnel.
Missing identity or capability denies every HTTP route, even with a pairing cookie.
Start serve before pairing. Runtime secrets never enter the Nix store or startup log.
Browser cookies expire after 30 days and are invalidated by server restart.
Questions and permission approvals remain in the terminal.
Web Push uses outbound HTTPS to Google, Mozilla or Apple push services."#
        );
        return Ok(());
    }
    if args.len() > 1
        || args
            .first()
            .is_some_and(|arg| arg != "serve" && arg != "pair")
    {
        return Err("usage: omp-phone [serve|pair] (see --help)".into());
    }
    let config = Config::load()?;
    if args.first().is_some_and(|arg| arg == "pair") {
        let token = config::read_private(&config.dir.join("token"))?
            .ok_or("start omp-phone serve before pairing")?;
        let token = token.trim();
        if token.len() != 43
            || !token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err("invalid token file".into());
        }
        println!("{}/#token={token}", config.origin);
        return Ok(());
    }
    // Refuse a second listener before generating secrets.
    let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, config.port)).await?;
    config::private_directory(&config.dir)?;
    let _state_lock = config::lock_state(&config.dir)?;
    let extension_listener = config::ExtensionListener::bind(&config.dir)?;
    let token = config::token(&config.dir)?;
    let push = push::Push::load(&config.dir, &config.origin)?;
    let (turns, turns_rx) = mpsc::channel(32);
    let push_worker = tokio::spawn(push.clone().worker(turns_rx));
    let (events, _) = broadcast::channel(16);
    let (shutdown, _) = watch::channel(false);
    let app = Arc::new(App {
        config,
        token,
        logins: Mutex::new(HashMap::new()),
        registry: Mutex::new(Registry::default()),
        events,
        shutdown,
        next_connection: AtomicU64::new(1),
        sockets: Arc::new(Semaphore::new(64)),
        push,
        turns,
    });
    let mut stopping = app.shutdown.subscribe();
    let extension_worker = tokio::spawn(extensions(app.clone(), extension_listener));
    eprintln!(
        "omp-phone: listening on http://127.0.0.1:{}; run `omp-phone pair` to pair a browser",
        app.config.port
    );
    let stop = app.clone();
    let server = axum::serve(listener, router(app.clone())).with_graceful_shutdown(async move {
        tokio::select! {
            _ = shutdown_signal() => {},
            _ = stopping.changed() => {},
        }
        stop.shutdown.send_replace(true);
    });
    let result = server.await;
    app.shutdown.send_replace(true);
    extension_worker.await??;
    push_worker.abort();
    result?;
    Ok(())
}

async fn shutdown_signal() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("install SIGTERM handler");
    tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
}

fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/health", get(|| async { Json(json!({"ok": true})) }))
        .route(
            "/",
            get(|| async {
                asset(
                    "text/html; charset=utf-8",
                    include_str!("../web/index.html"),
                )
            }),
        )
        .route(
            "/app.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_str!("../web/app.js"),
                )
            }),
        )
        .route(
            "/style.css",
            get(|| async { asset("text/css; charset=utf-8", include_str!("../web/style.css")) }),
        )
        .route(
            "/sw.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_str!("../web/sw.js"),
                )
            }),
        )
        .route(
            "/manifest.webmanifest",
            get(|| async {
                asset(
                    "application/manifest+json",
                    include_str!("../web/manifest.webmanifest"),
                )
            }),
        )
        .route(
            "/icon.svg",
            get(|| async { asset("image/svg+xml", include_str!("../web/icon.svg")) }),
        )
        .route("/api/login", post(login))
        .route("/api/logout", post(logout))
        .route("/api/sessions", get(snapshot))
        .route("/api/events", get(events))
        .route("/api/sessions/{id}/prompt", post(prompt))
        .route("/api/sessions/{id}/abort", post(abort))
        .route("/api/push/key", get(push_key))
        .route(
            "/api/push/subscriptions",
            post(subscribe).delete(unsubscribe),
        )
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn_with_state(app.clone(), protect))
        .with_state(app)
}

fn asset(content_type: &'static str, content: &'static str) -> impl IntoResponse {
    ([(header::CONTENT_TYPE, content_type)], content)
}

fn equal_secret(left: &str, right: &str) -> bool {
    left.as_bytes().ct_eq(right.as_bytes()).into()
}
fn cookie(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .filter_map(|part| part.trim().split_once('='))
        .find_map(|(name, value)| (name == COOKIE).then_some(value))
}
fn authenticated(app: &App, headers: &HeaderMap) -> bool {
    let Some(token) = cookie(headers) else {
        return false;
    };
    let mut logins = app.logins.lock();
    logins.retain(|_, deadline| *deadline > Instant::now());
    logins.get(token).is_some()
}
fn valid_origin(app: &App, headers: &HeaderMap, required: bool) -> bool {
    match headers.get(header::ORIGIN) {
        Some(origin) => origin
            .to_str()
            .is_ok_and(|origin| app.config.origins.iter().any(|allowed| allowed == origin)),
        None => !required,
    }
}

fn single_header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    let mut values = headers.get_all(name).iter();
    let value = values.next()?.to_str().ok()?;
    values.next().is_none().then_some(value)
}

fn tailnet_authorized(config: &Config, headers: &HeaderMap) -> bool {
    if headers.contains_key("tailscale-funnel-request") {
        return false;
    }
    if !config.secure {
        // A forgotten publicUrl must not silently expose the development UI via Serve.
        return !headers.keys().any(|name| {
            name.as_str().starts_with("tailscale-")
                || name.as_str().starts_with("x-forwarded-")
                || name.as_str() == "forwarded"
        });
    }
    let Some(login) = single_header(headers, "tailscale-user-login") else {
        return false;
    };
    if !config
        .allowed_tailnet_users
        .iter()
        .any(|allowed| allowed == login)
    {
        return false;
    }
    let Some(capabilities) = single_header(headers, "tailscale-app-capabilities")
        .and_then(|value| serde_json::from_str::<serde_json::Value>(value).ok())
    else {
        return false;
    };
    // This capability must be granted only to direct members in the tailnet
    // policy. A login header alone also admits users of shared devices.
    capabilities
        .get(&config.tailnet_capability)
        .and_then(serde_json::Value::as_array)
        .is_some_and(|grants| {
            grants
                .iter()
                .any(|grant| grant.get("access").and_then(serde_json::Value::as_bool) == Some(true))
        })
}

async fn protect(
    State(app): State<Arc<App>>,
    request: axum::extract::Request,
    next: Next,
) -> Response {
    let path = request.uri().path();
    let headers = request.headers();
    let host = headers
        .get(header::HOST)
        .and_then(|host| host.to_str().ok());
    let host_ok = host.is_some_and(|host| app.config.hosts.iter().any(|allowed| allowed == host));
    let mut response = if !tailnet_authorized(&app.config, headers) {
        ApiError::new(StatusCode::FORBIDDEN, "private tailnet access required").into_response()
    } else if !host_ok {
        ApiError::new(StatusCode::FORBIDDEN, "unrecognized host").into_response()
    } else if path.starts_with("/api/") {
        let write = request.method() != Method::GET && request.method() != Method::HEAD;
        if !valid_origin(&app, headers, write)
            || headers
                .get("sec-fetch-site")
                .is_some_and(|value| value == "cross-site")
        {
            ApiError::new(StatusCode::FORBIDDEN, "unrecognized or missing origin").into_response()
        } else if path != "/api/login" && !authenticated(&app, headers) {
            ApiError::new(StatusCode::UNAUTHORIZED, "pair this browser to continue").into_response()
        } else {
            next.run(request).await
        }
    } else {
        next.run(request).await
    };
    if response.status().is_client_error()
        && !response
            .headers()
            .get(header::CONTENT_TYPE)
            .is_some_and(|value| value.as_bytes().starts_with(b"application/json"))
    {
        response = ApiError::new(
            response.status(),
            response
                .status()
                .canonical_reason()
                .unwrap_or("request rejected"),
        )
        .into_response();
    }
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert("content-security-policy", HeaderValue::from_static("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"));
    if app.config.secure {
        headers.insert(
            "strict-transport-security",
            HeaderValue::from_static("max-age=31536000"),
        );
    }
    response
}

fn set_cookie(app: &App, token: &str, age: u64) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={age}{}",
        if app.config.secure { "; Secure" } else { "" }
    ))
    .unwrap()
}
#[derive(Deserialize)]
struct Login {
    token: String,
}
async fn login(State(app): State<Arc<App>>, Json(input): Json<Login>) -> ApiResult<Response> {
    if !equal_secret(&input.token, &app.token) {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid pairing token",
        ));
    }
    let token = config::random_secret();
    let mut logins = app.logins.lock();
    logins.retain(|_, deadline| *deadline > Instant::now());
    if logins.len() >= 32 {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "too many paired browsers; log out an existing browser or restart the server",
        ));
    }
    logins.insert(token.clone(), Instant::now() + COOKIE_AGE);
    Ok((
        [(
            header::SET_COOKIE,
            set_cookie(&app, &token, COOKIE_AGE.as_secs()),
        )],
        Json(json!({"ok": true})),
    )
        .into_response())
}
async fn logout(State(app): State<Arc<App>>, headers: HeaderMap) -> Response {
    if let Some(token) = cookie(&headers) {
        app.logins.lock().remove(token);
    }
    (
        [(header::SET_COOKIE, set_cookie(&app, "", 0))],
        Json(json!({"ok": true})),
    )
        .into_response()
}
async fn snapshot(State(app): State<Arc<App>>) -> Json<sessions::Snapshot> {
    Json(app.registry.lock().snapshot(&app.config.hostname))
}
async fn events(State(app): State<Arc<App>>, headers: HeaderMap) -> impl IntoResponse {
    let mut updates = app.events.subscribe();
    let mut shutdown = app.shutdown.subscribe();
    let stream = async_stream::stream! {
        let mut check_login = tokio::time::interval(Duration::from_secs(15));
        loop {
            if *shutdown.borrow() || !authenticated(&app, &headers) { break; }
            let snapshot = app.registry.lock().snapshot(&app.config.hostname);
            yield Ok::<_, Infallible>(Event::default().event("sessions").json_data(snapshot).expect("serializable session"));
            tokio::select! {
                _ = updates.recv() => {},
                _ = shutdown.changed() => { break; },
                _ = check_login.tick() => {},
            }
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(10)))
}

#[derive(Deserialize)]
struct Prompt {
    text: String,
}
async fn prompt(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Json(input): Json<Prompt>,
) -> ApiResult<Json<serde_json::Value>> {
    if input.text.trim().is_empty() || input.text.len() > 32 * 1024 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "prompt must contain 1–32768 bytes",
        ));
    }
    command(app, id, "prompt", Some(input.text)).await
}
async fn abort(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    command(app, id, "abort", None).await
}

struct PendingRequest {
    app: Arc<App>,
    id: String,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        self.app.registry.lock().pending.remove(&self.id);
    }
}

async fn command(
    app: Arc<App>,
    id: String,
    action: &str,
    text: Option<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let request_id = config::random_secret();
    let (send, receive) = oneshot::channel();
    {
        let mut registry = app.registry.lock();
        if registry.pending.len() >= 256 {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "too many pending commands",
            ));
        }
        let entry = registry
            .sessions
            .get(&id)
            .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "session disconnected"))?;
        let owner = entry.owner;
        let message = json!({"type": "command", "requestId": request_id, "sessionId": id, "action": action, "text": text}).to_string();
        entry.commands.try_send(message).map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "extension unavailable or command queue full; command not sent",
            )
        })?;
        registry.pending.insert(
            request_id.clone(),
            Pending {
                owner,
                session_id: id,
                result: send,
            },
        );
    }
    let _pending = PendingRequest {
        app: app.clone(),
        id: request_id,
    };
    let result = tokio::time::timeout(ACK_TIMEOUT, receive).await;
    match result {
        Ok(Ok(result)) if result.ok => Ok(Json(json!({"ok": true}))),
        Ok(Ok(result)) => Err(ApiError(
            StatusCode::CONFLICT,
            result
                .error
                .unwrap_or_else(|| "extension rejected command".into()),
        )),
        Ok(Err(_)) => Err(ApiError::new(
            StatusCode::CONFLICT,
            "session changed or disconnected; delivery uncertain; do not automatically retry",
        )),
        Err(_) => Err(ApiError::new(
            StatusCode::GATEWAY_TIMEOUT,
            "extension acknowledgment timed out; delivery uncertain; do not automatically retry",
        )),
    }
}

async fn push_key(State(app): State<Arc<App>>) -> Json<serde_json::Value> {
    Json(json!({"publicKey": app.push.public_key}))
}
async fn subscribe(
    State(app): State<Arc<App>>,
    Json(sub): Json<web_push::SubscriptionInfo>,
) -> ApiResult<Json<serde_json::Value>> {
    push::validate(&sub).map_err(|error| ApiError(StatusCode::BAD_REQUEST, error.to_string()))?;
    app.push.subscribe(sub).await.map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "could not save push subscription (limit 32 browsers)",
        )
    })?;
    Ok(Json(json!({"ok": true})))
}
#[derive(Deserialize)]
struct Endpoint {
    endpoint: String,
}
async fn unsubscribe(
    State(app): State<Arc<App>>,
    Json(input): Json<Endpoint>,
) -> ApiResult<Json<serde_json::Value>> {
    app.push.unsubscribe(&input.endpoint).await.map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "could not remove push subscription",
        )
    })?;
    Ok(Json(json!({"ok": true})))
}

async fn extensions(app: Arc<App>, listener: config::ExtensionListener) -> Result<()> {
    let mut shutdown = app.shutdown.subscribe();
    loop {
        if *shutdown.borrow() {
            return Ok(());
        }
        tokio::select! {
            _ = shutdown.changed() => return Ok(()),
            accepted = listener.listener.accept() => {
                let (socket, _) = match accepted {
                    Ok(accepted) => accepted,
                    Err(error) => {
                        app.shutdown.send_replace(true);
                        return Err(error.into());
                    }
                };
                let Ok(permit) = app.sockets.clone().try_acquire_owned() else { continue; };
                let owner = app.next_connection.fetch_add(1, Ordering::Relaxed);
                let app = app.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    extension_socket(app, Framed::new(socket, LinesCodec::new_with_max_length(1024 * 1024)), owner).await;
                });
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Incoming {
    Pong {},
    Snapshot {
        session: Session,
    },
    Result {
        #[serde(rename = "requestId")]
        request_id: String,
        ok: bool,
        error: Option<String>,
    },
}

type LocalSocket = Framed<tokio::net::UnixStream, LinesCodec>;

async fn extension_socket(app: Arc<App>, mut socket: LocalSocket, owner: u64) {
    let (commands, mut receive) = mpsc::channel::<String>(32);
    let mut shutdown = app.shutdown.subscribe();
    let mut ping = tokio::time::interval(Duration::from_secs(20));
    let mut last_seen = Instant::now();
    loop {
        if *shutdown.borrow() {
            break;
        }
        tokio::select! {
            _ = shutdown.changed() => break,
            _ = ping.tick() => {
                if last_seen.elapsed() > Duration::from_secs(60) { break; }
                if !send_local(&mut socket, r#"{"type":"ping"}"#).await { break; }
            }
            message = receive.recv() => {
                let Some(message) = message else { break; };
                if !send_local(&mut socket, &message).await { break; }
            }
            message = socket.next() => {
                last_seen = Instant::now();
                match message {
                    Some(Ok(text)) => {
                        match serde_json::from_str::<Incoming>(&text) {
                            Ok(Incoming::Pong {}) => {},
                            Ok(Incoming::Snapshot { session }) => {
                                let notification = push::Turn { hostname: app.config.hostname.clone(), title: session.title.clone(), id: session.id.clone() };
                                let result = app.registry.lock().update(owner, session, commands.clone());
                                match result {
                                    Ok(turn) => {
                                        let _ = app.events.send(());
                                        if turn && app.turns.try_send(notification).is_err() { eprintln!("omp-phone: notification queue full; turn notification not delivered"); }
                                    }
                                    Err(()) => break,
                                }
                            }
                            Ok(Incoming::Result { request_id, ok, error }) => {
                                if request_id.len() > 128 || error.as_ref().is_some_and(|error| error.len() > 4096) { break; }
                                app.registry.lock().acknowledge(owner, &request_id, CommandResult { ok, error });
                            }
                            Err(_) => break,
                        }
                    }
                    _ => break,
                }
            }
        }
    }
    if app.registry.lock().remove_owner(owner) {
        let _ = app.events.send(());
    }
    let _ = tokio::time::timeout(
        Duration::from_secs(1),
        <LocalSocket as SinkExt<String>>::close(&mut socket),
    )
    .await;
}

async fn send_local(socket: &mut LocalSocket, message: &str) -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(5), socket.send(message)).await,
        Ok(Ok(()))
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    fn test_app() -> (Arc<App>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            dir: dir.path().to_owned(),
            port: 8787,
            origin: "https://phone.example".into(),
            origins: vec!["https://phone.example".into()],
            hosts: vec![
                "phone.example".into(),
                "127.0.0.1:8787".into(),
                "localhost:8787".into(),
            ],
            allowed_tailnet_users: vec!["owner@example.com".into()],
            tailnet_capability: "example.com/cap/omp-phone".into(),
            secure: true,
            hostname: "test".into(),
        };
        let push = push::Push::load(&config.dir, &config.origin).unwrap();
        let (events, _) = broadcast::channel(2);
        let (shutdown, _) = watch::channel(false);
        let (turns, _) = mpsc::channel(2);
        (
            Arc::new(App {
                config,
                token: config::random_secret(),
                logins: Mutex::new(HashMap::new()),
                registry: Mutex::new(Registry::default()),
                events,
                shutdown,
                next_connection: AtomicU64::new(1),
                sockets: Arc::new(Semaphore::new(2)),
                push,
                turns,
            }),
            dir,
        )
    }

    fn request(
        method: Method,
        path: &str,
        origin: Option<&str>,
        cookie: Option<&str>,
        body: serde_json::Value,
    ) -> Request<Body> {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header(header::HOST, "phone.example")
            .header("tailscale-user-login", "owner@example.com")
            .header(
                "tailscale-app-capabilities",
                r#"{"example.com/cap/omp-phone":[{"access":true}]}"#,
            )
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(origin) = origin {
            request = request.header(header::ORIGIN, origin);
        }
        if let Some(cookie) = cookie {
            request = request.header(header::COOKIE, cookie);
        }
        request.body(Body::from(body.to_string())).unwrap()
    }

    #[tokio::test]
    async fn pairing_requires_exact_origin_and_logout_revokes_cookie() {
        let (app, _dir) = test_app();
        let routes = router(app.clone());
        let read = || request(Method::GET, "/api/sessions", None, None, json!({}));
        assert_eq!(
            routes.clone().oneshot(read()).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        for origin in [None, Some("https://phone.example.evil.test"), Some("null")] {
            let response = routes
                .clone()
                .oneshot(request(
                    Method::POST,
                    "/api/login",
                    origin,
                    None,
                    json!({"token": app.token}),
                ))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
        }
        let response = routes
            .clone()
            .oneshot(request(
                Method::POST,
                "/api/login",
                Some("https://phone.example"),
                None,
                json!({"token": "wrong"}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let response = routes
            .clone()
            .oneshot(request(
                Method::POST,
                "/api/login",
                Some("https://phone.example"),
                None,
                json!({"token": app.token}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let set_cookie = response.headers()[header::SET_COOKIE].to_str().unwrap();
        assert!(set_cookie.contains("; HttpOnly; SameSite=Strict;"));
        assert!(set_cookie.ends_with("; Secure"));
        let cookie = set_cookie.split(';').next().unwrap();
        assert_eq!(
            routes
                .clone()
                .oneshot(request(
                    Method::GET,
                    "/api/sessions",
                    None,
                    Some(cookie),
                    json!({})
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        // Possessing a valid cookie does not make cross-origin writes acceptable.
        assert_eq!(
            routes
                .clone()
                .oneshot(request(
                    Method::POST,
                    "/api/logout",
                    None,
                    Some(cookie),
                    json!({})
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            routes
                .clone()
                .oneshot(request(
                    Method::POST,
                    "/api/logout",
                    Some("https://phone.example"),
                    Some(cookie),
                    json!({})
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            routes
                .oneshot(request(
                    Method::GET,
                    "/api/sessions",
                    None,
                    Some(cookie),
                    json!({})
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn pairing_never_bypasses_tailnet_authorization() {
        let (app, _dir) = test_app();
        let routes = router(app.clone());
        let paired = routes
            .clone()
            .oneshot(request(
                Method::POST,
                "/api/login",
                Some("https://phone.example"),
                None,
                json!({"token": app.token}),
            ))
            .await
            .unwrap();
        assert_eq!(paired.status(), StatusCode::OK);
        let cookie = paired.headers()[header::SET_COOKIE]
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap();

        // Previously-public assets, login and streaming must share the same gate.
        for (method, path, host) in [
            (Method::GET, "/", "phone.example"),
            (Method::GET, "/app.js", "phone.example"),
            (Method::GET, "/health", "localhost:8787"),
            (Method::POST, "/api/login", "127.0.0.1:8787"),
            (Method::GET, "/api/events", "phone.example"),
        ] {
            let mut input = request(
                method,
                path,
                Some("https://phone.example"),
                Some(cookie),
                json!({"token": app.token}),
            );
            input
                .headers_mut()
                .insert(header::HOST, HeaderValue::from_str(host).unwrap());
            input.headers_mut().remove("tailscale-user-login");
            assert_eq!(
                routes.clone().oneshot(input).await.unwrap().status(),
                StatusCode::FORBIDDEN,
                "{path}"
            );
        }

        let allowed = || request(Method::GET, "/api/sessions", None, Some(cookie), json!({}));
        assert_eq!(
            routes.clone().oneshot(allowed()).await.unwrap().status(),
            StatusCode::OK
        );
        for (name, value) in [
            ("tailscale-user-login", "shared-outsider@example.com"),
            (
                "tailscale-user-login",
                "owner@example.com,shared-outsider@example.com",
            ),
            ("tailscale-app-capabilities", "{}"),
            (
                "tailscale-app-capabilities",
                r#"{"example.com/cap/omp-phone":[{"access":false}]}"#,
            ),
            ("tailscale-app-capabilities", "invalid JSON"),
            ("tailscale-funnel-request", "?1"),
        ] {
            let mut input = allowed();
            input
                .headers_mut()
                .insert(name, HeaderValue::from_str(value).unwrap());
            assert_eq!(
                routes.clone().oneshot(input).await.unwrap().status(),
                StatusCode::FORBIDDEN
            );
        }
        let mut no_capability = allowed();
        no_capability
            .headers_mut()
            .remove("tailscale-app-capabilities");
        assert_eq!(
            routes
                .clone()
                .oneshot(no_capability)
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN
        );
        for name in ["tailscale-user-login", "tailscale-app-capabilities"] {
            let mut input = allowed();
            let duplicate = input.headers()[name].clone();
            input.headers_mut().append(name, duplicate);
            assert_eq!(
                routes.clone().oneshot(input).await.unwrap().status(),
                StatusCode::FORBIDDEN
            );
        }
    }

    #[tokio::test]
    async fn http_cannot_open_extension_control_even_with_every_credential() {
        let (app, _dir) = test_app();
        let mut input = request(Method::GET, "/extension", None, None, json!({}));
        input.headers_mut().insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", app.token)).unwrap(),
        );
        input
            .headers_mut()
            .insert(header::CONNECTION, HeaderValue::from_static("upgrade"));
        input
            .headers_mut()
            .insert(header::UPGRADE, HeaderValue::from_static("websocket"));
        input
            .headers_mut()
            .insert("sec-websocket-version", HeaderValue::from_static("13"));
        input.headers_mut().insert(
            "sec-websocket-key",
            HeaderValue::from_static("dGhlIHNhbXBsZSBub25jZQ=="),
        );
        assert_eq!(
            router(app).oneshot(input).await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
    }
}
