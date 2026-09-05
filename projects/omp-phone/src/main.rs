mod config;
mod push;
mod sessions;

use axum::{
    extract::{
        ws::{Message as WsMessage, WebSocket},
        ConnectInfo, DefaultBodyLimit, Path, State, WebSocketUpgrade,
    },
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
use futures_util::SinkExt;
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::json;
use sessions::{CommandResult, Pending, Registry, Session};
use std::{
    collections::HashMap,
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, mpsc, oneshot, watch, Semaphore};

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
        println!("omp-phone [serve|pair]\n\nserve (default): bind the local companion to 127.0.0.1; use Tailscale Serve for HTTPS.\npair: print the configured URL with a secret pairing fragment. Treat it as a password.\n\nEnvironment:\n  OMP_PHONE_PORT         Local port (default 8787)\n  OMP_PHONE_PUBLIC_URL   Exact external HTTPS origin (default http://localhost:8787)\n  OMP_PHONE_HOSTNAME     Display name for this machine\n  OMP_PHONE_STATE_DIR    Private runtime state directory\n                        (default $XDG_STATE_HOME/omp-phone or ~/.local/state/omp-phone)\n\nStart serve before pairing. Token, VAPID key and push subscriptions remain in private\nruntime files, never in a Nix store. Ordinary startup does not print the token.\nBrowser cookies expire after 30 days and are invalidated by server restart.\nQuestions and permission approvals remain in the terminal.\nWeb Push supports Google, Mozilla and Apple push services.");
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
    eprintln!(
        "omp-phone: listening on http://127.0.0.1:{}; run `omp-phone pair` to pair a browser",
        app.config.port
    );
    let stop = app.clone();
    let server = axum::serve(
        listener,
        router(app).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        shutdown_signal().await;
        stop.shutdown.send_replace(true);
    });
    let result = server.await;
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
        .route("/extension", get(extension))
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
    let mut response = if !host_ok {
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

async fn extension(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> ApiResult<Response> {
    if !peer.ip().is_loopback() || headers.contains_key(header::ORIGIN) {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "extension channel is loopback-only and unavailable to browsers",
        ));
    }
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if !token.is_some_and(|token| equal_secret(token, &app.token)) {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid extension credentials",
        ));
    }
    let permit = app
        .sockets
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::new(StatusCode::TOO_MANY_REQUESTS, "too many extensions"))?;
    let owner = app.next_connection.fetch_add(1, Ordering::Relaxed);
    Ok(ws
        .max_message_size(1024 * 1024)
        .max_frame_size(1024 * 1024)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            extension_socket(app, socket, owner).await;
        }))
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Incoming {
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

async fn extension_socket(app: Arc<App>, mut socket: WebSocket, owner: u64) {
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
                if !send_ws(&mut socket, WsMessage::Ping(Vec::new().into())).await { break; }
            }
            message = receive.recv() => {
                let Some(message) = message else { break; };
                if !send_ws(&mut socket, WsMessage::Text(message.into())).await { break; }
            }
            message = socket.recv() => {
                last_seen = Instant::now();
                match message {
                    Some(Ok(WsMessage::Text(text))) => {
                        match serde_json::from_str::<Incoming>(&text) {
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
                    Some(Ok(WsMessage::Ping(data))) => { if !send_ws(&mut socket, WsMessage::Pong(data)).await { break; } }
                    Some(Ok(WsMessage::Pong(_))) => {},
                    _ => break,
                }
            }
        }
    }
    if app.registry.lock().remove_owner(owner) {
        let _ = app.events.send(());
    }
    let _ = tokio::time::timeout(Duration::from_secs(1), socket.close()).await;
}

async fn send_ws(socket: &mut WebSocket, message: WsMessage) -> bool {
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
            hosts: vec!["phone.example".into()],
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
}
