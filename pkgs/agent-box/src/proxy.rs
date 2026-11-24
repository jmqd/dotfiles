//! The HTTPS proxy the container talks through. It terminates TLS for
//! github.com and api.github.com, applies the session's policy, and adds the
//! installation token on the way out. Every other host gets a plain tunnel
//! and no credentials.

use crate::github::Tokens;
use crate::policy::{self, Check, Decision, Grant, Host};
use crate::receive_pack::{self, Parse};
use anyhow::Context as _;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use bytes::{Bytes, BytesMut};
use http_body_util::combinators::UnsyncBoxBody;
use http_body_util::{BodyExt as _, Empty, Full, Limited};
use hyper::body::{Body, Frame, Incoming, SizeHint};
use hyper::header::{self, HeaderName, HeaderValue};
use hyper::http::request::Parts;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_rustls::HttpsConnector;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioIo;
use std::convert::Infallible;
use std::fs::File;
use std::io::Write as _;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;
pub type ProxyBody = UnsyncBoxBody<Bytes, BoxError>;

/// JSON bodies the policy reads (GraphQL, pull request creation, LFS batch)
/// are small; anything larger is not one of them.
const MAX_INSPECTED_BODY: usize = 8 << 20;

pub const PROXY_USER: &str = "agentbox";

/// Ports the plain tunnel serves. Agents and package managers need HTTPS
/// (and the odd HTTP redirect); nothing else leaves the box.
const TUNNEL_PORTS: &[u16] = &[443, 80];

/// Where session tokens come from. `Tokens` mints real installation tokens.
pub trait TokenSource: Send + Sync + 'static {
    fn token(&self) -> impl Future<Output = anyhow::Result<String>> + Send;
}

impl TokenSource for Tokens {
    fn token(&self) -> impl Future<Output = anyhow::Result<String>> + Send {
        self.get()
    }
}

/// The GitHub endpoints intercepted requests are forwarded to.
pub struct Upstream {
    client: Client<HttpsConnector<HttpConnector>, ProxyBody>,
    web: String,
    api: String,
}

impl Upstream {
    pub fn github() -> Self {
        Self {
            client: crate::github::https_client(),
            web: "https://github.com".into(),
            api: "https://api.github.com".into(),
        }
    }

    #[cfg(test)]
    pub fn new(
        client: Client<HttpsConnector<HttpConnector>, ProxyBody>,
        web: String,
        api: String,
    ) -> Self {
        Self { client, web, api }
    }

    fn base(&self, kind: Host) -> &str {
        match kind {
            Host::Web => &self.web,
            Host::Api => &self.api,
        }
    }
}

pub struct Proxy<T> {
    proxy_authorization: String,
    tls: TlsAcceptor,
    grant: Grant,
    tokens: T,
    upstream: Upstream,
    log: Mutex<File>,
}

impl<T: TokenSource> Proxy<T> {
    pub fn new(
        secret: &str,
        tls: TlsAcceptor,
        grant: Grant,
        tokens: T,
        upstream: Upstream,
        log: File,
    ) -> Self {
        Self {
            proxy_authorization: format!(
                "Basic {}",
                STANDARD.encode(format!("{PROXY_USER}:{secret}"))
            ),
            tls,
            grant,
            tokens,
            upstream,
            log: Mutex::new(log),
        }
    }

    pub async fn serve(self: Arc<Self>, listener: TcpListener) {
        loop {
            let stream = match listener.accept().await {
                Ok((stream, _)) => stream,
                Err(error) => {
                    self.record(&format!("accept failed: {error}"));
                    continue;
                }
            };
            let proxy = Arc::clone(&self);
            tokio::spawn(async move {
                let service = service_fn(|request| Arc::clone(&proxy).outer(request));
                let served = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(stream), service)
                    .with_upgrades()
                    .await;
                if let Err(error) = served {
                    proxy.record(&format!("proxy connection ended: {error}"));
                }
            });
        }
    }

    fn record(&self, line: &str) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        if let Ok(mut log) = self.log.lock() {
            // A log write failure must not fail the request it describes.
            if let Err(error) = writeln!(log, "{now} {line}") {
                eprintln!("agent-box: proxy log write failed: {error}");
            }
        }
    }

    async fn outer(
        self: Arc<Self>,
        request: Request<Incoming>,
    ) -> Result<Response<ProxyBody>, Infallible> {
        let authorized = request
            .headers()
            .get(header::PROXY_AUTHORIZATION)
            .is_some_and(|value| value.as_bytes() == self.proxy_authorization.as_bytes());
        if !authorized {
            let mut response = text(
                StatusCode::PROXY_AUTHENTICATION_REQUIRED,
                "agent-box: proxy login required\n",
            );
            response.headers_mut().insert(
                header::PROXY_AUTHENTICATE,
                HeaderValue::from_static("Basic realm=\"agent-box\""),
            );
            return Ok(response);
        }
        if request.method() != Method::CONNECT {
            return Ok(text(
                StatusCode::METHOD_NOT_ALLOWED,
                "agent-box: only HTTPS (CONNECT) is proxied\n",
            ));
        }
        let Some(authority) = request.uri().authority().cloned() else {
            return Ok(text(
                StatusCode::BAD_REQUEST,
                "agent-box: CONNECT needs host:port\n",
            ));
        };
        let host = authority.host().to_ascii_lowercase();
        let port = authority.port_u16().unwrap_or(443);
        // Connect before answering, so a refused or failed target is an
        // HTTP error the client can show rather than a dropped tunnel.
        let route = match (host.as_str(), port) {
            ("github.com", 443) => Route::Intercept(Host::Web),
            ("api.github.com", 443) => Route::Intercept(Host::Api),
            _ => match self.connect_public(&host, port).await {
                Ok(stream) => Route::Tunnel(stream),
                Err((status, reason)) => {
                    self.record(&format!("deny CONNECT {host}:{port}: {reason}"));
                    let message = format!("agent-box refused CONNECT {host}:{port}: {reason}\n");
                    return Ok(text(status, &message));
                }
            },
        };

        tokio::spawn(async move {
            let upgraded = match hyper::upgrade::on(request).await {
                Ok(upgraded) => TokioIo::new(upgraded),
                Err(error) => return self.record(&format!("upgrade failed for {host}: {error}")),
            };
            match route {
                Route::Intercept(kind) => self.intercept(kind, upgraded).await,
                Route::Tunnel(upstream) => self.tunnel(upgraded, upstream, &host, port).await,
            }
        });
        Ok(Response::new(
            Empty::new().map_err(|never| match never {}).boxed_unsync(),
        ))
    }

    /// The box may reach the internet, never the Mac's loopback services or
    /// the LAN: those would bypass the VM. The checked address is the one
    /// connected to, so DNS cannot swap it afterwards.
    async fn connect_public(
        &self,
        host: &str,
        port: u16,
    ) -> Result<TcpStream, (StatusCode, String)> {
        if !TUNNEL_PORTS.contains(&port) {
            let reason = format!("only ports {TUNNEL_PORTS:?} are tunneled");
            return Err((StatusCode::FORBIDDEN, reason));
        }
        // URI authorities bracket IPv6 literals; the resolver wants them bare.
        let bare = host
            .strip_prefix('[')
            .and_then(|inner| inner.strip_suffix(']'))
            .unwrap_or(host);
        let addresses: Vec<SocketAddr> = tokio::net::lookup_host((bare, port))
            .await
            .map_err(|error| (StatusCode::BAD_GATEWAY, format!("cannot resolve: {error}")))?
            .collect();
        let Some(address) = addresses.iter().find(|address| is_public(address.ip())) else {
            return Err((StatusCode::FORBIDDEN, "not a public address".into()));
        };
        TcpStream::connect(address)
            .await
            .map_err(|error| (StatusCode::BAD_GATEWAY, format!("cannot connect: {error}")))
    }

    async fn intercept(self: Arc<Self>, kind: Host, client: TokioIo<hyper::upgrade::Upgraded>) {
        let stream = match self.tls.accept(client).await {
            Ok(stream) => stream,
            Err(error) => {
                return self.record(&format!("TLS handshake with the container failed: {error}"));
            }
        };
        let proxy = Arc::clone(&self);
        let service = service_fn(move |request| {
            let proxy = Arc::clone(&proxy);
            async move { Ok::<_, Infallible>(proxy.inner(kind, request).await) }
        });
        let served = hyper::server::conn::http1::Builder::new()
            .serve_connection(TokioIo::new(stream), service)
            .await;
        if let Err(error) = served {
            self.record(&format!("{} connection ended: {error}", host_name(kind)));
        }
    }

    async fn inner(&self, kind: Host, request: Request<Incoming>) -> Response<ProxyBody> {
        let (mut parts, body) = request.into_parts();
        let target = format!("{} {}{}", parts.method, host_name(kind), parts.uri.path());
        let check = policy::check_request(&self.grant, kind, &parts.method, parts.uri.path());
        let inspected = !matches!(check, Check::Done(_));
        if inspected && parts.headers.contains_key(header::CONTENT_ENCODING) {
            return self.deny(&target, "compressed bodies cannot be checked");
        }
        let body = match check {
            Check::Done(Decision::Deny(reason)) => return self.deny(&target, &reason),
            Check::Done(Decision::Allow) => body.map_err(BoxError::from).boxed_unsync(),
            Check::RefUpdates => match read_ref_updates(&self.grant, body).await {
                Ok(body) => body.boxed_unsync(),
                Err(reason) => return self.deny(&target, &reason),
            },
            Check::Body(rule) => {
                let bytes = match Limited::new(body, MAX_INSPECTED_BODY).collect().await {
                    Ok(collected) => collected.to_bytes(),
                    Err(error) => return self.deny(&target, &format!("unreadable body: {error}")),
                };
                if let Decision::Deny(reason) = policy::check_body(&self.grant, rule, &bytes) {
                    return self.deny(&target, &reason);
                }
                parts.headers.remove(header::CONTENT_LENGTH);
                Full::new(bytes)
                    .map_err(|never| match never {})
                    .boxed_unsync()
            }
        };
        match self.forward(kind, parts, body).await {
            Ok(response) => {
                self.record(&format!("allow {} {target}", response.status().as_u16()));
                response
            }
            Err(error) => {
                self.record(&format!("error {target}: {error:#}"));
                text(StatusCode::BAD_GATEWAY, &format!("agent-box: {error:#}\n"))
            }
        }
    }

    fn deny(&self, target: &str, reason: &str) -> Response<ProxyBody> {
        self.record(&format!("deny {target}: {reason}"));
        text(
            StatusCode::FORBIDDEN,
            &format!("agent-box denied {target}: {reason}\n"),
        )
    }

    async fn forward(
        &self,
        kind: Host,
        parts: Parts,
        body: ProxyBody,
    ) -> anyhow::Result<Response<ProxyBody>> {
        let token = self.tokens.token().await?;
        let path = parts.uri.path_and_query().map_or("/", |pq| pq.as_str());
        let mut request = Request::builder()
            .method(parts.method)
            .uri(format!("{}{path}", self.upstream.base(kind)));
        let headers = request.headers_mut().context("invalid request")?;
        for (name, value) in &parts.headers {
            if !is_hop_by_hop(name) && name != header::HOST && name != header::AUTHORIZATION {
                headers.append(name, value.clone());
            }
        }
        let authorization = match kind {
            Host::Web => format!(
                "Basic {}",
                STANDARD.encode(format!("x-access-token:{token}"))
            ),
            Host::Api => format!("Bearer {token}"),
        };
        headers.insert(header::AUTHORIZATION, HeaderValue::try_from(authorization)?);

        let response = self.upstream.client.request(request.body(body)?).await?;
        let (mut parts, body) = response.into_parts();
        let hop_by_hop: Vec<HeaderName> = parts
            .headers
            .keys()
            .filter(|name| is_hop_by_hop(name))
            .cloned()
            .collect();
        for name in hop_by_hop {
            parts.headers.remove(name);
        }
        Ok(Response::from_parts(
            parts,
            body.map_err(BoxError::from).boxed_unsync(),
        ))
    }

    async fn tunnel(
        &self,
        mut client: TokioIo<hyper::upgrade::Upgraded>,
        mut upstream: TcpStream,
        host: &str,
        port: u16,
    ) {
        // Either side closing ends the tunnel; resets are routine.
        if let Err(error) = tokio::io::copy_bidirectional(&mut client, &mut upstream).await {
            self.record(&format!("tunnel to {host}:{port} ended: {error}"));
        }
    }
}

enum Route {
    Intercept(Host),
    Tunnel(TcpStream),
}

fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, _] = v4.octets();
            !(v4.is_unspecified()
                || v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_multicast()
                || a == 0
                || a >= 240
                || (a == 100 && (64..128).contains(&b))
                || (a == 192 && b == 0 && c == 0)
                || (a == 198 && (18..20).contains(&b)))
        }
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_public(IpAddr::V4(v4)),
            None => {
                let first = v6.segments()[0];
                !(v6.is_unspecified()
                    || v6.is_loopback()
                    || v6.is_multicast()
                    || (first & 0xfe00) == 0xfc00
                    || (first & 0xffc0) == 0xfe80)
            }
        },
    }
}

fn host_name(kind: Host) -> &'static str {
    match kind {
        Host::Web => "github.com",
        Host::Api => "api.github.com",
    }
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    [
        header::CONNECTION,
        header::PROXY_AUTHENTICATE,
        header::PROXY_AUTHORIZATION,
        header::TE,
        header::TRAILER,
        header::TRANSFER_ENCODING,
        header::UPGRADE,
    ]
    .contains(name)
        || name.as_str() == "keep-alive"
}

fn text(status: StatusCode, message: &str) -> Response<ProxyBody> {
    let mut response = Response::new(
        Full::new(Bytes::from(message.to_owned()))
            .map_err(|never| match never {})
            .boxed_unsync(),
    );
    *response.status_mut() = status;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response
}

/// Reads a push's ref updates, then hands back a body that replays them
/// ahead of the rest of the stream so the pack itself is never buffered.
async fn read_ref_updates(grant: &Grant, mut body: Incoming) -> Result<PrefixedBody, String> {
    let mut prefix = BytesMut::new();
    let updates = loop {
        match receive_pack::parse_commands(&prefix) {
            Parse::Commands(updates) => break updates,
            Parse::Invalid(reason) => return Err(reason),
            Parse::Incomplete => {}
        }
        match body.frame().await {
            Some(Ok(frame)) => {
                if let Ok(data) = frame.into_data() {
                    prefix.extend_from_slice(&data);
                }
            }
            Some(Err(error)) => return Err(format!("unreadable push: {error}")),
            None => return Err("push ended before its ref updates".into()),
        }
    };
    match policy::check_ref_updates(grant, &updates) {
        Decision::Allow => Ok(PrefixedBody {
            prefix: Some(prefix.freeze()),
            rest: body,
        }),
        Decision::Deny(reason) => Err(reason),
    }
}

struct PrefixedBody {
    prefix: Option<Bytes>,
    rest: Incoming,
}

impl Body for PrefixedBody {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        if let Some(prefix) = self.prefix.take() {
            return Poll::Ready(Some(Ok(Frame::data(prefix))));
        }
        Pin::new(&mut self.rest)
            .poll_frame(cx)
            .map_err(BoxError::from)
    }

    fn is_end_stream(&self) -> bool {
        self.prefix.is_none() && self.rest.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        let rest = self.rest.size_hint();
        let prefix = self.prefix.as_ref().map_or(0, |prefix| prefix.len() as u64);
        let mut hint = SizeHint::new();
        if let Some(upper) = rest.upper() {
            hint.set_upper(upper + prefix);
        }
        hint.set_lower(rest.lower() + prefix);
        hint
    }
}
