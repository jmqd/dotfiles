//! Drives real `git` and `curl` clients through the proxy to a local stand-in
//! for GitHub: `git http-backend` behind TLS from a test CA. Only the network
//! boundary is faked; the proxy, its TLS interception, policy, and token
//! injection are the shipped code.

use crate::policy::{Access, Grant};
use crate::proxy::{PROXY_USER, Proxy, ProxyBody, TokenSource, Upstream};
use crate::target::RepoId;
use crate::tls::SessionCa;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use bytes::Bytes;
use http_body_util::{BodyExt as _, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::client::legacy::Client;
use hyper_util::rt::{TokioExecutor, TokioIo};
use rcgen::{BasicConstraints, CertificateParams, CertifiedIssuer, IsCa, KeyPair};
use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use tokio::io::AsyncWriteExt as _;
use tokio::net::TcpListener;

const TOKEN: &str = "test-installation-token";
const SECRET: &str = "test-proxy-secret";

struct FixedToken;

impl TokenSource for FixedToken {
    async fn token(&self) -> anyhow::Result<String> {
        Ok(TOKEN.to_owned())
    }
}

/// Requests that reached the fake GitHub, as `METHOD path authorization`.
type Seen = Arc<Mutex<Vec<String>>>;

struct Harness {
    dir: tempfile::TempDir,
    proxy_url: String,
    ca_file: PathBuf,
    seen: Seen,
}

impl Harness {
    async fn start(grant: Grant) -> Self {
        install_crypto();
        let dir = tempfile::tempdir().expect("tempdir");
        let seen: Seen = Arc::default();
        let (upstream_port, upstream_roots) =
            start_fake_github(dir.path().join("upstream"), Arc::clone(&seen)).await;

        let mut roots = rustls::RootCertStore::empty();
        roots.add(upstream_roots).expect("test root");
        let tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let connector = hyper_rustls::HttpsConnectorBuilder::new()
            .with_tls_config(tls)
            .https_only()
            .enable_http1()
            .build();
        let client = Client::builder(TokioExecutor::new()).build::<_, ProxyBody>(connector);
        let base = format!("https://127.0.0.1:{upstream_port}");
        let upstream = Upstream::new(client, format!("{base}/web"), format!("{base}/api"));

        let ca = SessionCa::new(&["github.com", "api.github.com"]).expect("session CA");
        let ca_file = dir.path().join("session-ca.pem");
        std::fs::write(&ca_file, &ca.cert_pem).expect("write CA");
        let log = std::fs::File::create(dir.path().join("proxy.log")).expect("log");
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::clone(&ca.server_config));
        let proxy = Arc::new(Proxy::new(
            SECRET, acceptor, grant, FixedToken, upstream, log,
        ));
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind proxy");
        let proxy_port = listener.local_addr().expect("proxy addr").port();
        tokio::spawn(proxy.serve(listener));

        let harness = Self {
            proxy_url: format!("http://{PROXY_USER}:{SECRET}@127.0.0.1:{proxy_port}"),
            ca_file,
            seen,
            dir,
        };
        harness.seed_upstream();
        harness
    }

    fn proxy_log(&self) -> String {
        std::fs::read_to_string(self.path("proxy.log")).unwrap_or_default()
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn bare(&self) -> PathBuf {
        self.path("upstream/jmqd/dotfiles.git")
    }

    fn seed_upstream(&self) {
        let bare = self.bare();
        std::fs::create_dir_all(&bare).expect("bare dir");
        git_ok(
            &bare,
            &["init", "--bare", "--quiet", "--initial-branch=main"],
        );
        let seed = self.path("seed");
        std::fs::create_dir_all(&seed).expect("seed dir");
        git_ok(&seed, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(seed.join("README"), "seed\n").expect("write");
        git_ok(&seed, &["add", "README"]);
        git_ok(&seed, &["commit", "--quiet", "-m", "seed"]);
        let bare = bare.to_str().expect("utf-8 path");
        git_ok(&seed, &["push", "--quiet", bare, "main", "main:feature"]);
    }

    /// Runs git as the container would: through the proxy, trusting only the
    /// session CA, with no credentials of its own.
    fn git(&self, dir: &Path, args: &[&str]) -> Output {
        git_command(dir)
            .env("HTTPS_PROXY", &self.proxy_url)
            .env("https_proxy", &self.proxy_url)
            .env("GIT_SSL_CAINFO", &self.ca_file)
            .args(args)
            .output()
            .expect("run git")
    }

    fn curl(&self, args: &[&str]) -> String {
        let output = Command::new("curl")
            .args(["--silent", "--output", "/dev/null", "--cacert"])
            .arg(&self.ca_file)
            .args(["--proxy", &self.proxy_url])
            .args(args)
            .output()
            .expect("run curl");
        String::from_utf8(output.stdout).expect("utf-8")
    }

    fn upstream_ref(&self, name: &str) -> Option<String> {
        let output = git_command(&self.bare())
            .args(["rev-parse", "--verify", "--quiet", name])
            .output()
            .expect("rev-parse");
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    }

    fn api_requests(&self) -> Vec<String> {
        let seen = self.seen.lock().expect("seen");
        seen.iter()
            .filter(|line| line.contains(" /api/"))
            .cloned()
            .collect()
    }

    fn clone_and_commit(&self) -> PathBuf {
        let work = self.path("work");
        let cloned = self.git(
            self.dir.path(),
            &[
                "clone",
                "--quiet",
                "https://github.com/jmqd/dotfiles.git",
                "work",
            ],
        );
        assert!(cloned.status.success(), "clone: {}", stderr(&cloned));
        git_ok(&work, &["checkout", "--quiet", "feature"]);
        // Incompressible and larger than git's 1 MiB post buffer, so the push
        // is sent chunked and the proxy must replay the commands it read.
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        let noise: Vec<u8> = (0..3 << 20)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state.to_le_bytes()[0]
            })
            .collect();
        std::fs::write(work.join("noise.bin"), noise).expect("write");
        git_ok(&work, &["add", "noise.bin"]);
        git_ok(&work, &["commit", "--quiet", "-m", "agent change"]);
        work
    }
}

fn branch_grant() -> Grant {
    Grant {
        repo: RepoId {
            owner: "jmqd".into(),
            name: "dotfiles".into(),
        },
        repo_node_id: "R_repo".into(),
        access: Access::Branch("feature".into()),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn branch_session_pushes_its_branch_and_nothing_else() {
    let harness = Harness::start(branch_grant()).await;
    let work = harness.clone_and_commit();
    let head = String::from_utf8(
        git_command(&work)
            .args(["rev-parse", "HEAD"])
            .output()
            .expect("rev-parse")
            .stdout,
    )
    .expect("utf-8")
    .trim()
    .to_owned();
    let main_before = harness.upstream_ref("main");

    let pushed = harness.git(
        &work,
        &["push", "--quiet", "origin", "HEAD:refs/heads/feature"],
    );
    assert!(
        pushed.status.success(),
        "push to feature: {}\nproxy log:\n{}",
        stderr(&pushed),
        harness.proxy_log()
    );
    assert_eq!(
        harness.upstream_ref("feature").as_deref(),
        Some(head.as_str())
    );

    for refspec in [
        "HEAD:refs/heads/main",
        "HEAD:refs/tags/v1",
        ":refs/heads/feature",
    ] {
        let refused = harness.git(&work, &["push", "--quiet", "origin", refspec]);
        assert!(!refused.status.success(), "{refspec} was accepted");
        assert!(
            stderr(&refused).contains("403"),
            "{refspec}: {}",
            stderr(&refused)
        );
    }
    assert_eq!(harness.upstream_ref("main"), main_before);
    assert_eq!(harness.upstream_ref("v1"), None);
    assert_eq!(
        harness.upstream_ref("feature").as_deref(),
        Some(head.as_str())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fork_pr_session_cannot_push_at_all() {
    let harness = Harness::start(Grant {
        access: Access::Pr {
            number: 7,
            node_id: "PR_seven".into(),
            head: crate::policy::PrHead::Fork,
        },
        ..branch_grant()
    })
    .await;
    let work = harness.clone_and_commit();
    let refused = harness.git(
        &work,
        &["push", "--quiet", "origin", "HEAD:refs/heads/feature"],
    );
    assert!(!refused.status.success());
    assert_ne!(
        harness.upstream_ref("feature"),
        Some(
            String::from_utf8_lossy(
                &git_command(&work)
                    .args(["rev-parse", "HEAD"])
                    .output()
                    .expect("rev-parse")
                    .stdout
            )
            .trim()
            .to_owned()
        )
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn graphql_mutations_outside_the_grant_never_reach_github() {
    let harness = Harness::start(branch_grant()).await;
    let mutation = r#"{"query":"mutation { mergePullRequest(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }"}"#;
    let status = harness.curl(&[
        "--write-out",
        "%{http_code}",
        "--data",
        mutation,
        "https://api.github.com/graphql",
    ]);
    assert_eq!(status, "403");
    assert!(harness.api_requests().is_empty());

    let query = r#"{"query":"query { viewer { login } }"}"#;
    let status = harness.curl(&[
        "--write-out",
        "%{http_code}",
        "--data",
        query,
        "https://api.github.com/graphql",
    ]);
    assert_eq!(status, "200");
    assert_eq!(
        harness.api_requests(),
        [format!("POST /api/graphql Bearer {TOKEN}")]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_proxy_refuses_strangers_and_private_destinations() {
    let harness = Harness::start(branch_grant()).await;
    let wrong_login = harness.proxy_url.replace(SECRET, "guess");
    let output = Command::new("curl")
        .args([
            "--silent",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_connect}",
            "--proxy",
            &wrong_login,
        ])
        .arg("https://example.com/")
        .output()
        .expect("curl");
    assert_eq!(String::from_utf8_lossy(&output.stdout), "407");

    for target in [
        "https://127.0.0.1/",
        "https://10.0.0.1/",
        "https://[::1]/",
        "https://example.com:22/",
    ] {
        let status = harness.curl(&["--write-out", "%{http_connect}", target]);
        assert_eq!(status, "403", "{target}");
    }
}

fn git_command(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_AUTHOR_NAME", "agent")
        .env("GIT_AUTHOR_EMAIL", "agent@example.com")
        .env("GIT_COMMITTER_NAME", "agent")
        .env("GIT_COMMITTER_EMAIL", "agent@example.com")
        .env_remove("HTTPS_PROXY")
        .env_remove("https_proxy");
    command
}

fn git_ok(dir: &Path, args: &[&str]) {
    let output = git_command(dir).args(args).output().expect("run git");
    assert!(output.status.success(), "git {args:?}: {}", stderr(&output));
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn install_crypto() {
    // Every test installs the same provider; only the first call can win.
    drop(rustls::crypto::ring::default_provider().install_default());
}

/// Serves `/web/...` with `git http-backend` over `root` and `/api/...` with
/// an empty JSON object, each only for the expected token. Returns the port
/// and the root certificate clients must trust.
async fn start_fake_github(
    root: PathBuf,
    seen: Seen,
) -> (u16, rustls::pki_types::CertificateDer<'static>) {
    let mut ca_params = CertificateParams::new(Vec::<String>::new()).expect("params");
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca =
        CertifiedIssuer::self_signed(ca_params, KeyPair::generate().expect("key")).expect("CA");
    let leaf_key = KeyPair::generate().expect("key");
    let leaf = CertificateParams::new(vec!["127.0.0.1".to_owned()])
        .expect("params")
        .signed_by(&leaf_key, &ca)
        .expect("leaf");
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![leaf.der().clone()],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
        )
        .expect("server config");
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind upstream");
    let port = listener.local_addr().expect("addr").port();
    let root = Arc::new(root);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let (acceptor, root, seen) = (acceptor.clone(), Arc::clone(&root), Arc::clone(&seen));
            tokio::spawn(async move {
                let Ok(stream) = acceptor.accept(stream).await else {
                    return;
                };
                let service = service_fn(move |request| {
                    let (root, seen) = (Arc::clone(&root), Arc::clone(&seen));
                    async move { Ok::<_, Infallible>(fake_github(request, &root, &seen).await) }
                });
                drop(
                    hyper::server::conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(stream), service)
                        .await,
                );
            });
        }
    });
    (port, ca.der().clone())
}

async fn fake_github(
    request: Request<Incoming>,
    root: &Path,
    seen: &Mutex<Vec<String>>,
) -> Response<Full<Bytes>> {
    let (parts, body) = request.into_parts();
    let authorization = parts
        .headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let path = parts.uri.path().to_owned();
    seen.lock()
        .expect("seen")
        .push(format!("{} {path} {authorization}", parts.method));
    let respond = |status: StatusCode, body: Vec<u8>| {
        let mut response = Response::new(Full::new(Bytes::from(body)));
        *response.status_mut() = status;
        response
    };
    let body = body.collect().await.expect("body").to_bytes();

    if let Some(path_info) = path.strip_prefix("/web") {
        let basic = format!(
            "Basic {}",
            STANDARD.encode(format!("x-access-token:{TOKEN}"))
        );
        if authorization != basic {
            return respond(StatusCode::UNAUTHORIZED, b"bad token".to_vec());
        }
        let header = |name: &str| {
            parts
                .headers
                .get(name)
                .and_then(|value| value.to_str().ok())
                .unwrap_or_default()
                .to_owned()
        };
        let mut child = tokio::process::Command::new("git")
            .arg("http-backend")
            .env("GIT_PROJECT_ROOT", root)
            .env("GIT_HTTP_EXPORT_ALL", "1")
            .env("REMOTE_USER", "agent")
            .env("REMOTE_ADDR", "127.0.0.1")
            .env("REQUEST_METHOD", parts.method.as_str())
            .env("PATH_INFO", path_info)
            .env("QUERY_STRING", parts.uri.query().unwrap_or_default())
            .env("CONTENT_TYPE", header("content-type"))
            .env("CONTENT_LENGTH", body.len().to_string())
            .env("HTTP_CONTENT_ENCODING", header("content-encoding"))
            .env("HTTP_GIT_PROTOCOL", header("git-protocol"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("git http-backend");
        let mut stdin = child.stdin.take().expect("stdin");
        stdin.write_all(&body).await.expect("write body");
        drop(stdin);
        let output = child.wait_with_output().await.expect("http-backend output");
        return cgi_response(&output.stdout);
    }
    if path.starts_with("/api/") {
        if authorization != format!("Bearer {TOKEN}") {
            return respond(StatusCode::UNAUTHORIZED, b"bad token".to_vec());
        }
        return respond(StatusCode::OK, b"{}".to_vec());
    }
    respond(StatusCode::NOT_FOUND, Vec::new())
}

fn cgi_response(output: &[u8]) -> Response<Full<Bytes>> {
    let split = output
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|at| (at, at + 4))
        .or_else(|| {
            output
                .windows(2)
                .position(|window| window == b"\n\n")
                .map(|at| (at, at + 2))
        })
        .expect("CGI header end");
    let head = String::from_utf8_lossy(&output[..split.0]);
    let mut response = Response::new(Full::new(Bytes::copy_from_slice(&output[split.1..])));
    for line in head.lines() {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("status") {
            let code = value
                .split(' ')
                .next()
                .and_then(|code| code.parse().ok())
                .expect("status");
            *response.status_mut() = StatusCode::from_u16(code).expect("status code");
        } else {
            response.headers_mut().append(
                hyper::header::HeaderName::from_bytes(name.as_bytes()).expect("header name"),
                value.parse().expect("header value"),
            );
        }
    }
    response
}
