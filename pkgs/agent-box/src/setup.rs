//! One-time creation of the GitHub App that mints session tokens, through
//! GitHub's app-manifest flow: the browser confirms, and the private key comes
//! back to this process, which stores it with sops.

use crate::github::{self, Auth};
use anyhow::{Context as _, anyhow, ensure};
use bytes::Bytes;
use http_body_util::Full;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{Value as Json, json};
use std::convert::Infallible;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;
use tokio::sync::oneshot;

pub async fn setup(key_file: &Path, org: Option<&str>) -> anyhow::Result<()> {
    ensure!(
        !key_file.exists(),
        "{} already exists; move it away to create a new app",
        key_file.display()
    );
    let parent = key_file
        .parent()
        .context("key file has no parent directory")?;
    std::fs::create_dir_all(parent)?;
    // Fail before creating an app whose key could not be stored.
    encrypt(key_file, &json!({ "probe": true }))
        .context("sops cannot encrypt to this path; add a creation rule for it to .sops.yaml")?;

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let state = crate::random_hex(16)?;
    let manifest = json!({
        "name": format!("agent-box-{}", crate::random_hex(3)?),
        "url": "https://github.com/jmqd/dotfiles",
        "redirect_url": format!("http://127.0.0.1:{port}/callback"),
        "public": false,
        "default_permissions": github::permissions(),
        "default_events": [],
    });
    let action = match org {
        Some(org) => {
            format!("https://github.com/organizations/{org}/settings/apps/new?state={state}")
        }
        None => format!("https://github.com/settings/apps/new?state={state}"),
    };
    let page = format!(
        "<!doctype html><title>agent-box setup</title>\
         <form id=f method=post action=\"{}\"><input type=hidden name=manifest value=\"{}\">\
         <button>Create the agent-box GitHub App</button></form>\
         <script>document.getElementById('f').submit()</script>",
        html_escape(&action),
        html_escape(&manifest.to_string()),
    );

    let code = receive_code(listener, page, state, port).await?;
    let path = format!("/app-manifests/{code}/conversions");
    let (status, app) = github::call(
        &github::https_client(),
        Method::POST,
        &path,
        Auth::None,
        None,
    )
    .await?;
    ensure!(
        status.is_success(),
        "GitHub did not create the app: {status} {app}"
    );
    let field = |key: &str| {
        app.get(key)
            .cloned()
            .ok_or_else(|| anyhow!("app response has no {key}"))
    };
    let slug = field("slug")?;
    let slug = slug.as_str().context("app slug is not a string")?;
    let stored = json!({ "app_id": field("id")?, "slug": slug, "private_key": field("pem")? });
    let encrypted = encrypt(key_file, &stored)?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(key_file)?
        .write_all(&encrypted)?;
    eprintln!(
        "agent-box: stored the {slug} app key in {}",
        key_file.display()
    );

    let install = format!("https://github.com/apps/{slug}/installations/new");
    eprintln!("agent-box: install the app on the repos agents may use: {install}");
    open_browser(&install);
    Ok(())
}

async fn receive_code(
    listener: TcpListener,
    page: String,
    state: String,
    port: u16,
) -> anyhow::Result<String> {
    let (sender, receiver) = oneshot::channel::<String>();
    let sender = Arc::new(Mutex::new(Some(sender)));
    let page = Arc::new(page);
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let (sender, page, state) = (Arc::clone(&sender), Arc::clone(&page), state.clone());
            tokio::spawn(async move {
                let service = service_fn(move |request: Request<hyper::body::Incoming>| {
                    let response = respond(&request, &page, &state, &sender);
                    async move { Ok::<_, Infallible>(response) }
                });
                let served = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(stream), service)
                    .await;
                if let Err(error) = served {
                    eprintln!("agent-box: browser connection ended: {error}");
                }
            });
        }
    });
    let start = format!("http://127.0.0.1:{port}/");
    eprintln!("agent-box: confirm the new GitHub App in your browser: {start}");
    open_browser(&start);
    let code = receiver.await.context("setup server stopped")?;
    server.abort();
    Ok(code)
}

fn respond(
    request: &Request<hyper::body::Incoming>,
    page: &str,
    state: &str,
    sender: &Mutex<Option<oneshot::Sender<String>>>,
) -> Response<Full<Bytes>> {
    let html = |status, body: &str| {
        let mut response = Response::new(Full::new(Bytes::from(body.to_owned())));
        *response.status_mut() = status;
        response
    };
    match request.uri().path() {
        "/" => html(StatusCode::OK, page),
        "/callback" => {
            let query = request.uri().query().unwrap_or_default();
            let param = |name: &str| {
                query
                    .split('&')
                    .filter_map(|pair| pair.split_once('='))
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| value)
            };
            match (param("code"), param("state")) {
                (Some(code), Some(got)) if got == state => {
                    let sender = sender.lock().ok().and_then(|mut sender| sender.take());
                    match sender.map(|sender| sender.send(code.to_owned())) {
                        Some(Ok(())) => html(
                            StatusCode::OK,
                            "agent-box: app created; return to your terminal.",
                        ),
                        _ => html(
                            StatusCode::CONFLICT,
                            "agent-box: setup is no longer waiting for this callback",
                        ),
                    }
                }
                _ => html(StatusCode::BAD_REQUEST, "agent-box: unexpected callback"),
            }
        }
        _ => html(StatusCode::NOT_FOUND, "not found"),
    }
}

fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Encrypts `value` with the sops creation rule that matches `path`.
fn encrypt(path: &Path, value: &Json) -> anyhow::Result<Vec<u8>> {
    let directory = path.parent().context("key file has no parent directory")?;
    let mut child = Command::new("sops")
        .current_dir(directory)
        .args([
            "--encrypt",
            "--input-type",
            "json",
            "--output-type",
            "yaml",
            "--filename-override",
        ])
        .arg(path)
        .arg("/dev/stdin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to run sops")?;
    child
        .stdin
        .take()
        .context("sops stdin")?
        .write_all(value.to_string().as_bytes())?;
    let output = child.wait_with_output()?;
    ensure!(
        output.status.success(),
        "sops failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(output.stdout)
}

fn open_browser(url: &str) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let opened = Command::new(opener)
        .arg(url)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if !opened.is_ok_and(|status| status.success()) {
        eprintln!("agent-box: could not open a browser; open the URL above yourself");
    }
}
