use crate::config::{self, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::{stream, StreamExt};
use p256::SecretKey;
use rand::rngs::OsRng;
use serde_json::json;
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::{mpsc, Mutex};
use url::Url;
use web_push::{
    ContentEncoding, PartialVapidSignatureBuilder, SubscriptionInfo, VapidSignatureBuilder,
    WebPushMessageBuilder,
};

pub struct Push {
    pub public_key: String,
    subscriptions: Mutex<Vec<SubscriptionInfo>>,
    path: PathBuf,
    key: PartialVapidSignatureBuilder,
    subject: String,
    client: reqwest::Client,
}

pub struct Turn {
    pub hostname: String,
    pub title: String,
    pub id: String,
}

enum Delivery {
    Sent,
    Expired,
    Failed,
}

impl Push {
    pub fn load(dir: &std::path::Path, origin: &str) -> Result<Arc<Self>> {
        let key_path = dir.join("vapid-key");
        let encoded = match config::read_private(&key_path)? {
            Some(key) => key,
            None => {
                let key = URL_SAFE_NO_PAD.encode(SecretKey::random(&mut OsRng).to_bytes());
                config::create_private(&key_path, &key)?;
                key
            }
        };
        let key = VapidSignatureBuilder::from_base64_no_sub(encoded.trim())?;
        let path = dir.join("subscriptions.json");
        let subscriptions: Vec<SubscriptionInfo> = match config::read_private(&path)? {
            Some(text) => serde_json::from_str(&text)?,
            None => Vec::new(),
        };
        if subscriptions.len() > 32 || subscriptions.iter().any(|sub| validate(sub).is_err()) {
            return Err("invalid saved push subscriptions".into());
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .build()?;
        Ok(Arc::new(Self {
            public_key: URL_SAFE_NO_PAD.encode(key.get_public_key()),
            subscriptions: Mutex::new(subscriptions),
            path,
            key,
            subject: origin.to_owned(),
            client,
        }))
    }

    pub async fn subscribe(&self, sub: SubscriptionInfo) -> Result<()> {
        validate(&sub)?;
        let mut current = self.subscriptions.lock().await;
        let mut next = current.clone();
        next.retain(|old| old.endpoint != sub.endpoint);
        if next.len() >= 32 {
            return Err("at most 32 push subscriptions are supported".into());
        }
        next.push(sub);
        self.persist(&next).await?;
        *current = next;
        Ok(())
    }

    pub async fn unsubscribe(&self, endpoint: &str) -> Result<()> {
        let mut current = self.subscriptions.lock().await;
        let mut next = current.clone();
        next.retain(|sub| sub.endpoint != endpoint);
        self.persist(&next).await?;
        *current = next;
        Ok(())
    }

    async fn persist(&self, subscriptions: &[SubscriptionInfo]) -> Result<()> {
        let path = self.path.clone();
        let text = serde_json::to_string(subscriptions)?;
        tokio::task::spawn_blocking(move || config::save_private(&path, &text)).await??;
        Ok(())
    }

    pub async fn worker(self: Arc<Self>, mut turns: mpsc::Receiver<Turn>) {
        while let Some(turn) = turns.recv().await {
            let payload = json!({
                "title": format!("{} · Your turn", turn.hostname),
                "body": turn.title,
                "url": format!("/#session={}", turn.id),
            })
            .to_string();
            let subscriptions = self.subscriptions.lock().await.clone();
            let service = self.as_ref();
            let expired: Vec<_> = stream::iter(subscriptions.into_iter().map(|sub| {
                let payload = &payload;
                async move {
                    match service.deliver(&sub, payload.as_bytes()).await {
                        Delivery::Expired => Some(sub),
                        _ => None,
                    }
                }
            }))
            .buffer_unordered(4)
            .filter_map(|sub| async move { sub })
            .collect()
            .await;
            if !expired.is_empty() {
                let mut current = self.subscriptions.lock().await;
                let mut next = current.clone();
                next.retain(|sub| !expired.contains(sub));
                if self.persist(&next).await.is_ok() {
                    *current = next;
                } else {
                    eprintln!("omp-phone: could not persist expired push subscription removal");
                }
            }
        }
    }

    async fn deliver(&self, sub: &SubscriptionInfo, payload: &[u8]) -> Delivery {
        // Recheck persisted endpoints as well as browser submissions. Redirects and
        // environment proxies are disabled: subscription endpoints are credentials.
        if validate(sub).is_err() {
            return Delivery::Expired;
        }
        let message = (|| {
            let mut signature = self.key.clone().add_sub_info(sub);
            signature.add_claim("sub", self.subject.clone());
            let mut message = WebPushMessageBuilder::new(sub);
            message.set_payload(ContentEncoding::Aes128Gcm, payload);
            message.set_vapid_signature(signature.build()?);
            message.set_ttl(300);
            message.build()
        })();
        let message = match message {
            Ok(message) => message,
            Err(error) => {
                eprintln!(
                    "omp-phone: push encryption failed: {}",
                    error.short_description()
                );
                return Delivery::Failed;
            }
        };
        let (parts, body) =
            web_push::request_builder::build_request::<reqwest::Body>(message).into_parts();
        let mut request = self.client.post(sub.endpoint.as_str()).body(body);
        for (name, value) in &parts.headers {
            request = request.header(name.as_str(), value.as_bytes());
        }
        match request.send().await {
            Ok(response) if response.status().is_success() => Delivery::Sent,
            Ok(response) if matches!(response.status().as_u16(), 404 | 410) => Delivery::Expired,
            Ok(response) => {
                eprintln!(
                    "omp-phone: push service rejected notification (HTTP {})",
                    response.status().as_u16()
                );
                Delivery::Failed
            }
            Err(_) => {
                eprintln!("omp-phone: push delivery failed or timed out");
                Delivery::Failed
            }
        }
    }
}

pub fn validate(sub: &SubscriptionInfo) -> Result<()> {
    if sub.endpoint.len() > 4096 {
        return Err("push endpoint is too long".into());
    }
    let url = Url::parse(&sub.endpoint).map_err(|_| "invalid push endpoint")?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
        || url.fragment().is_some()
        || !matches!(
            url.host_str(),
            Some("fcm.googleapis.com" | "updates.push.services.mozilla.com" | "web.push.apple.com")
        )
    {
        return Err(
            "push endpoint must use a supported HTTPS push service (Google, Mozilla, or Apple)"
                .into(),
        );
    }
    let key = URL_SAFE_NO_PAD
        .decode(&sub.keys.p256dh)
        .map_err(|_| "invalid push public key")?;
    if key.len() != 65 || p256::PublicKey::from_sec1_bytes(&key).is_err() {
        return Err("invalid push public key".into());
    }
    if URL_SAFE_NO_PAD
        .decode(&sub.keys.auth)
        .map_or(true, |auth| auth.len() != 16)
    {
        return Err("invalid push authentication key".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    #[test]
    fn endpoints_cannot_target_local_services_or_lookalike_hosts() {
        let public = SecretKey::random(&mut OsRng).public_key();
        let mut sub = SubscriptionInfo::new(
            "https://fcm.googleapis.com/send/test".to_owned(),
            URL_SAFE_NO_PAD.encode(public.to_encoded_point(false).as_bytes()),
            URL_SAFE_NO_PAD.encode([1; 16]),
        );
        assert!(validate(&sub).is_ok());
        for endpoint in [
            "http://fcm.googleapis.com/x",
            "https://127.0.0.1/x",
            "https://fcm.googleapis.com.evil.test/x",
            "https://fcm.googleapis.com:8443/x",
            "https://user@fcm.googleapis.com/x",
            "https://evil.test@fcm.googleapis.com/x",
        ] {
            sub.endpoint = endpoint.into();
            assert!(validate(&sub).is_err(), "accepted {endpoint}");
        }
    }
}
