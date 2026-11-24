//! GitHub App authentication: signs app JWTs and mints installation tokens
//! limited to one repository.

use crate::policy::{Access, Grant, PrHead};
use crate::target::{RepoId, Scope, Target};
use anyhow::{Context as _, anyhow, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use bytes::Bytes;
use http_body_util::{BodyExt as _, Full};
use hyper::{Method, Request, StatusCode};
use hyper_rustls::HttpsConnector;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use serde::Deserialize;
use serde_json::{Value as Json, json};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

pub const API: &str = "https://api.github.com";
pub const USER_AGENT: &str = "agent-box";

/// Everything a session may do to its repo. The proxy narrows writes per
/// grant; these bound what any token can do. `workflows`, `administration`
/// and `secrets` are absent: a pushed workflow file runs with the repo's
/// secrets.
pub fn permissions() -> Json {
    json!({
        "actions": "read",
        "checks": "read",
        "contents": "write",
        "issues": "write",
        "metadata": "read",
        "pull_requests": "write",
        "statuses": "read",
    })
}

/// Installation tokens live an hour; refresh with margin for in-flight requests.
const TOKEN_REFRESH_AFTER: Duration = Duration::from_secs(50 * 60);

pub type HttpsClient = Client<HttpsConnector<HttpConnector>, Full<Bytes>>;

pub fn https_client<B>() -> Client<HttpsConnector<HttpConnector>, B>
where
    B: hyper::body::Body + Send + Unpin + 'static,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    let connector = hyper_rustls::HttpsConnectorBuilder::new()
        .with_webpki_roots()
        .https_only()
        .enable_http1()
        .build();
    Client::builder(TokioExecutor::new()).build(connector)
}

pub struct App {
    pub id: u64,
    pub slug: String,
    key: RsaKeyPair,
}

#[derive(Deserialize)]
struct StoredApp {
    app_id: u64,
    slug: String,
    private_key: String,
}

impl App {
    /// Decrypts the app credentials written by `agent-box setup`.
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        ensure!(
            path.exists(),
            "no GitHub App credentials at {}; run `agent-box setup` first",
            path.display()
        );
        let output = Command::new("sops")
            .args(["--decrypt", "--output-type", "json"])
            .arg(path)
            .output()
            .context("failed to run sops")?;
        ensure!(
            output.status.success(),
            "sops could not decrypt {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        let stored: StoredApp = serde_json::from_slice(&output.stdout)
            .context("GitHub App credentials have the wrong shape")?;
        Ok(Self {
            id: stored.app_id,
            slug: stored.slug,
            key: parse_rsa_pem(&stored.private_key)?,
        })
    }

    fn jwt(&self) -> anyhow::Result<String> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        // GitHub allows ten minutes; backdate a minute for clock skew.
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let claims = URL_SAFE_NO_PAD
            .encode(json!({ "iat": now - 60, "exp": now + 540, "iss": self.id }).to_string());
        let message = format!("{header}.{claims}");
        let mut signature = vec![0; self.key.public().modulus_len()];
        self.key
            .sign(
                &RSA_PKCS1_SHA256,
                &SystemRandom::new(),
                message.as_bytes(),
                &mut signature,
            )
            .map_err(|_| anyhow!("failed to sign the GitHub App JWT"))?;
        Ok(format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature)))
    }
}

fn parse_rsa_pem(pem: &str) -> anyhow::Result<RsaKeyPair> {
    let body: String = pem
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect();
    let der = STANDARD
        .decode(body.trim())
        .context("GitHub App private key is not PEM")?;
    if pem.contains("BEGIN RSA PRIVATE KEY") {
        RsaKeyPair::from_der(&der).map_err(|e| anyhow!("invalid PKCS#1 key: {e}"))
    } else {
        RsaKeyPair::from_pkcs8(&der).map_err(|e| anyhow!("invalid PKCS#8 key: {e}"))
    }
}

pub enum Auth<'a> {
    None,
    Bearer(&'a str),
}

pub async fn call(
    client: &HttpsClient,
    method: Method,
    path: &str,
    auth: Auth<'_>,
    body: Option<Json>,
) -> anyhow::Result<(StatusCode, Json)> {
    let mut request = Request::builder()
        .method(method.clone())
        .uri(format!("{API}{path}"))
        .header("accept", "application/vnd.github+json")
        .header("user-agent", USER_AGENT)
        .header("x-github-api-version", "2022-11-28");
    if let Auth::Bearer(token) = auth {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let body = match body {
        Some(body) => {
            request = request.header("content-type", "application/json");
            Full::new(Bytes::from(body.to_string()))
        }
        None => Full::new(Bytes::new()),
    };
    let response = client
        .request(request.body(body)?)
        .await
        .with_context(|| format!("{method} {path} failed"))?;
    let status = response.status();
    let bytes = response.into_body().collect().await?.to_bytes();
    let json = if bytes.is_empty() {
        Json::Null
    } else {
        serde_json::from_slice(&bytes)
            .with_context(|| format!("{method} {path} returned non-JSON"))?
    };
    Ok((status, json))
}

fn api_error(what: &str, status: StatusCode, body: &Json) -> anyhow::Error {
    let message = body
        .get("message")
        .and_then(Json::as_str)
        .unwrap_or_default();
    anyhow!("{what}: GitHub returned {status}: {message}")
}

/// Mints and caches installation tokens limited to one repository.
pub struct Tokens {
    app: App,
    client: HttpsClient,
    installation_id: u64,
    repo: RepoId,
    current: Mutex<Option<(String, Instant)>>,
}

impl Tokens {
    pub async fn new(app: App, client: HttpsClient, repo: RepoId) -> anyhow::Result<Self> {
        let jwt = app.jwt()?;
        let path = format!("/repos/{}/{}/installation", repo.owner, repo.name);
        let (status, body) = call(&client, Method::GET, &path, Auth::Bearer(&jwt), None).await?;
        if status == StatusCode::NOT_FOUND {
            bail!(
                "the agent-box GitHub App is not installed for {repo}; install it at https://github.com/apps/{}/installations/new",
                app.slug
            );
        }
        ensure!(
            status.is_success(),
            api_error("finding the app installation", status, &body)
        );
        let installation_id = body
            .get("id")
            .and_then(Json::as_u64)
            .context("installation response has no id")?;
        let tokens = Self {
            app,
            client,
            installation_id,
            repo,
            current: Mutex::new(None),
        };
        tokens.get().await?;
        Ok(tokens)
    }

    pub async fn get(&self) -> anyhow::Result<String> {
        let mut current = self.current.lock().await;
        if let Some((token, minted)) = current.as_ref()
            && minted.elapsed() < TOKEN_REFRESH_AFTER
        {
            return Ok(token.clone());
        }
        let jwt = self.app.jwt()?;
        let path = format!("/app/installations/{}/access_tokens", self.installation_id);
        let request = json!({ "repositories": [self.repo.name], "permissions": permissions() });
        let (status, body) = call(
            &self.client,
            Method::POST,
            &path,
            Auth::Bearer(&jwt),
            Some(request),
        )
        .await?;
        ensure!(
            status.is_success(),
            api_error(&format!("minting a token for {}", self.repo), status, &body)
        );
        let token = body
            .get("token")
            .and_then(Json::as_str)
            .context("token response has no token")?
            .to_owned();
        *current = Some((token.clone(), Instant::now()));
        Ok(token)
    }

    /// Resolves the target into the grant the proxy enforces.
    pub async fn grant(&self, target: &Target) -> anyhow::Result<Grant> {
        let token = self.get().await?;
        let repo = &target.repo;
        let path = format!("/repos/{}/{}", repo.owner, repo.name);
        let (status, body) =
            call(&self.client, Method::GET, &path, Auth::Bearer(&token), None).await?;
        ensure!(
            status.is_success(),
            api_error(&format!("reading {repo}"), status, &body)
        );
        let repo_node_id = node_id(&body)?;

        let access = match &target.scope {
            Scope::Repo => Access::Repo,
            Scope::Branch(branch) => Access::Branch(branch.clone()),
            Scope::Pr(number) => {
                let path = format!("/repos/{}/{}/pulls/{number}", repo.owner, repo.name);
                let (status, pr) =
                    call(&self.client, Method::GET, &path, Auth::Bearer(&token), None).await?;
                ensure!(
                    status.is_success(),
                    api_error(&format!("reading PR #{number}"), status, &pr)
                );
                let head_repo = pr.pointer("/head/repo/full_name").and_then(Json::as_str);
                let head_ref = pr.pointer("/head/ref").and_then(Json::as_str);
                // A deleted fork leaves head.repo null; treat it as a fork.
                let head = match (head_repo.and_then(|full| full.split_once('/')), head_ref) {
                    (Some((owner, name)), Some(head_ref)) if repo.is(owner, name) => {
                        PrHead::SameRepo(head_ref.to_owned())
                    }
                    _ => PrHead::Fork,
                };
                Access::Pr {
                    number: *number,
                    node_id: node_id(&pr)?,
                    head,
                }
            }
        };
        Ok(Grant {
            repo: repo.clone(),
            repo_node_id,
            access,
        })
    }
}

fn node_id(body: &Json) -> anyhow::Result<String> {
    Ok(body
        .get("node_id")
        .and_then(Json::as_str)
        .context("GitHub response has no node_id")?
        .to_owned())
}
