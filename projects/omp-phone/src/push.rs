use crate::{
    config::{self, Result},
    sessions::{Role, Session},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::{stream, StreamExt};
use p256::{
    ecdsa::{signature::Signer, Signature, SigningKey},
    elliptic_curve::Generate,
    SecretKey,
};
use rand::rngs::SysRng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, Mutex};
use url::Url;

// Keep the browser and persisted subscription JSON unchanged.
#[derive(Clone, Deserialize, Serialize, PartialEq)]
pub struct Subscription {
    endpoint: String,
    keys: SubscriptionKeys,
}

#[derive(Clone, Deserialize, Serialize, PartialEq)]
struct SubscriptionKeys {
    p256dh: String,
    auth: String,
}

pub struct Recipient {
    endpoint: Url,
    public_key: Vec<u8>,
    auth: Vec<u8>,
}

pub struct Push {
    pub public_key: String,
    subscriptions: Mutex<Vec<Subscription>>,
    path: PathBuf,
    key: SigningKey,
    subject: String,
    client: reqwest::Client,
}

pub struct Turn {
    payload: String,
}

impl Turn {
    pub fn new(hostname: &str, session: &Session) -> Self {
        let mut body = session.title.clone();
        // Do not search past a newer user message or tool result for an old answer.
        if let Some(message) = session
            .messages
            .last()
            .filter(|m| matches!(m.role, Role::Assistant))
        {
            let preview = response_preview(&message.text);
            if !preview.is_empty() {
                body.push('\n');
                body.push_str(&preview);
            }
        }
        Self {
            payload: json!({
                "title": format!("{hostname} · Your turn"),
                "body": body,
                "url": format!("/omp/#session={}", session.id),
            })
            .to_string(),
        }
    }
}

fn response_preview(text: &str) -> String {
    let mut characters = text
        .split_whitespace()
        .enumerate()
        .flat_map(|(index, word)| (index != 0).then_some(' ').into_iter().chain(word.chars()));
    let mut preview: String = characters.by_ref().take(160).collect();
    if characters.next().is_some() {
        preview.pop();
        preview.push('…');
    }
    preview
}

enum Delivery {
    Sent,
    Expired,
    Failed,
}

impl Push {
    pub fn load(dir: &std::path::Path, origin: &str) -> Result<Arc<Self>> {
        let key_path = dir.join("vapid-key");
        let (encoded, new_key) = match config::read_private(&key_path)? {
            Some(key) => (key, false),
            None => (
                URL_SAFE_NO_PAD.encode(SecretKey::try_generate_from_rng(&mut SysRng)?.to_bytes()),
                true,
            ),
        };
        let key = SigningKey::from_slice(&URL_SAFE_NO_PAD.decode(encoded.trim())?)?;
        let path = dir.join("subscriptions.json");
        let subscriptions: Vec<Subscription> = match config::read_private(&path)? {
            Some(text) => serde_json::from_str(&text)?,
            None => Vec::new(),
        };
        if subscriptions.len() > 32
            || subscriptions
                .iter()
                .any(|sub| parse_subscription(sub).is_err())
        {
            return Err("invalid saved push subscriptions".into());
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .build()?;
        if new_key {
            config::create_private(&key_path, &encoded)?;
        }
        Ok(Arc::new(Self {
            public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().to_sec1_point(false).as_bytes()),
            subscriptions: Mutex::new(subscriptions),
            path,
            key,
            subject: origin.to_owned(),
            client,
        }))
    }

    pub async fn subscribe(&self, sub: Subscription) -> Result<()> {
        parse_subscription(&sub)?;
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

    async fn persist(&self, subscriptions: &[Subscription]) -> Result<()> {
        let path = self.path.clone();
        let text = serde_json::to_string(subscriptions)?;
        tokio::task::spawn_blocking(move || config::save_private(&path, &text)).await??;
        Ok(())
    }

    pub async fn worker(self: Arc<Self>, mut turns: mpsc::Receiver<Turn>) {
        while let Some(turn) = turns.recv().await {
            let payload = turn.payload;
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

    fn request(
        &self,
        recipient: Recipient,
        payload: &[u8],
        now: SystemTime,
    ) -> Result<reqwest::Request> {
        // Preserve the previous payload limit, including room for ECE padding.
        if payload.len() > 3052 {
            return Err("push payload is too large".into());
        }
        let expires = now
            .duration_since(UNIX_EPOCH)?
            .as_secs()
            .checked_add(12 * 60 * 60)
            .ok_or("push token expiry overflow")?;
        // RFC 8292: ES256, the push service origin, and at most 24 hours of validity.
        let claims = serde_json::to_vec(&json!({
            "aud": recipient.endpoint.origin().unicode_serialization(),
            "exp": expires,
            "sub": self.subject,
        }))?;
        let mut token = URL_SAFE_NO_PAD.encode(br#"{"typ":"JWT","alg":"ES256"}"#);
        token.push('.');
        URL_SAFE_NO_PAD.encode_string(&claims, &mut token);
        let signature: Signature = self.key.try_sign(token.as_bytes())?;
        token.push('.');
        // JWS uses the fixed-width r || s signature, not ASN.1 DER.
        URL_SAFE_NO_PAD.encode_string(signature.to_bytes(), &mut token);
        let body = ece::encrypt(&recipient.public_key, &recipient.auth, payload)?;
        Ok(self
            .client
            .post(recipient.endpoint)
            .header(
                "Authorization",
                format!("vapid t={token}, k={}", self.public_key),
            )
            .header("TTL", "300")
            .header("Content-Encoding", "aes128gcm")
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", body.len())
            .body(body)
            .build()?)
    }

    async fn deliver(&self, sub: &Subscription, payload: &[u8]) -> Delivery {
        // Recheck persisted endpoints as well as browser submissions. Redirects and
        // environment proxies are disabled: subscription endpoints are credentials.
        let recipient = match parse_subscription(sub) {
            Ok(recipient) => recipient,
            Err(_) => return Delivery::Expired,
        };
        let request = match self.request(recipient, payload, SystemTime::now()) {
            Ok(request) => request,
            Err(_) => {
                eprintln!("omp-phone: push signing or encryption failed");
                return Delivery::Failed;
            }
        };
        match self.client.execute(request).await {
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

pub fn parse_subscription(sub: &Subscription) -> Result<Recipient> {
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
    let auth = URL_SAFE_NO_PAD
        .decode(&sub.keys.auth)
        .map_err(|_| "invalid push authentication key")?;
    if auth.len() != 16 {
        return Err("invalid push authentication key".into());
    }
    Ok(Recipient {
        endpoint: url,
        public_key: key,
        auth,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::elliptic_curve::sec1::ToSec1Point;

    #[test]
    fn preview_does_not_reuse_answers_before_user_or_tool_messages() {
        let mut session: Session = serde_json::from_value(json!({
            "id": "session-1", "title": "Deployment", "cwd": "/tmp", "state": "idle",
            "messages": [
                {"role": "user", "text": "Deploy the fix"},
                {"role": "assistant", "text": "  Deployed.\n\n All\tchecks passed.  "}
            ],
            "partial": "Unfinished streaming text"
        }))
        .unwrap();
        let payload = |session: &Session| -> serde_json::Value {
            serde_json::from_str(&Turn::new("Mac", session).payload).unwrap()
        };
        assert_eq!(
            payload(&session)["body"],
            "Deployment\nDeployed. All checks passed."
        );
        for role in [Role::User, Role::Tool] {
            session.messages.push(crate::sessions::Message {
                role,
                text: "Not an answer".into(),
            });
            assert_eq!(payload(&session)["body"], "Deployment");
            session.messages.pop();
        }
        session.messages.last_mut().unwrap().text = " \n\t".into();
        assert_eq!(payload(&session)["body"], "Deployment");
        session.messages.clear();
        assert_eq!(payload(&session)["body"], "Deployment");
    }

    #[test]
    fn preview_limits_unicode_text_without_truncating_exact_fit() {
        let text = "界".repeat(160);
        assert_eq!(response_preview(&text), text);
        assert_eq!(
            response_preview(&(text + "x")),
            format!("{}…", "界".repeat(159))
        );
    }

    #[test]
    fn endpoints_cannot_target_local_services_or_lookalike_hosts() {
        let public = SecretKey::try_generate_from_rng(&mut SysRng)
            .unwrap()
            .public_key();
        let mut sub = Subscription {
            endpoint: "https://fcm.googleapis.com/send/test".to_owned(),
            keys: SubscriptionKeys {
                p256dh: URL_SAFE_NO_PAD.encode(public.to_sec1_point(false).as_bytes()),
                auth: URL_SAFE_NO_PAD.encode([1; 16]),
            },
        };
        assert!(parse_subscription(&sub).is_ok());
        for endpoint in [
            "http://fcm.googleapis.com/x",
            "https://127.0.0.1/x",
            "https://fcm.googleapis.com.evil.test/x",
            "https://fcm.googleapis.com:8443/x",
            "https://user@fcm.googleapis.com/x",
            "https://evil.test@fcm.googleapis.com/x",
        ] {
            sub.endpoint = endpoint.into();
            assert!(parse_subscription(&sub).is_err(), "accepted {endpoint}");
        }
    }

    #[tokio::test]
    async fn persisted_identity_signs_interoperable_encrypted_push() {
        use openssl::{
            bn::{BigNum, BigNumContext},
            ec::{EcGroup, EcKey, EcPoint},
            ecdsa::EcdsaSig,
            hash::MessageDigest,
            nid::Nid,
            pkey::PKey,
            sign::Verifier,
        };

        let dir = tempfile::tempdir().unwrap();
        // Scalar 1 has the standard P-256 generator as its public key.
        let mut scalar = [0; 32];
        scalar[31] = 1;
        let encoded_key = URL_SAFE_NO_PAD.encode(scalar);
        let expected_public = "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU";
        config::create_private(&dir.path().join("vapid-key"), &encoded_key).unwrap();

        let receiver = SecretKey::from_slice(&[2; 32]).unwrap();
        let receiver_public = receiver.public_key().to_sec1_point(false);
        let auth = [3; 16];
        let saved = json!([{
            "endpoint": "https://web.push.apple.com/push/existing-subscription",
            "keys": {
                "p256dh": URL_SAFE_NO_PAD.encode(receiver_public.as_bytes()),
                "auth": URL_SAFE_NO_PAD.encode(auth),
            },
        }]);
        config::create_private(&dir.path().join("subscriptions.json"), &saved.to_string()).unwrap();
        let push = Push::load(dir.path(), "https://phone.example").unwrap();
        assert_eq!(push.public_key, expected_public);
        let sub = push.subscriptions.lock().await[0].clone();
        let now = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let payload = br#"{"title":"Your turn","body":"Ready","url":"/omp/#session=test"}"#;
        let request = push
            .request(parse_subscription(&sub).unwrap(), payload, now)
            .unwrap();
        assert_eq!(request.method(), reqwest::Method::POST);
        assert_eq!(request.url().as_str(), sub.endpoint);
        assert_eq!(request.headers()["ttl"], "300");
        assert_eq!(request.headers()["content-encoding"], "aes128gcm");
        assert_eq!(
            request.headers()["content-type"],
            "application/octet-stream"
        );

        let authorization = request.headers()["authorization"].to_str().unwrap();
        let (token, public) = authorization
            .strip_prefix("vapid t=")
            .unwrap()
            .split_once(", k=")
            .unwrap();
        assert_eq!(public, expected_public);
        let (signed, encoded_signature) = token.rsplit_once('.').unwrap();
        let (header, claims) = signed.split_once('.').unwrap();
        let decode_json = |encoded: &str| -> serde_json::Value {
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(encoded).unwrap()).unwrap()
        };
        assert_eq!(decode_json(header), json!({"typ": "JWT", "alg": "ES256"}));
        assert_eq!(
            decode_json(claims),
            json!({
                "aud": "https://web.push.apple.com",
                "exp": 1_800_043_200_u64,
                "sub": "https://phone.example",
            })
        );

        // Verify with OpenSSL, independently of the RustCrypto signer.
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
        let point = EcPoint::from_bytes(
            &group,
            &URL_SAFE_NO_PAD.decode(public).unwrap(),
            &mut BigNumContext::new().unwrap(),
        )
        .unwrap();
        let public_key =
            PKey::from_ec_key(EcKey::from_public_key(&group, &point).unwrap()).unwrap();
        let signature = URL_SAFE_NO_PAD.decode(encoded_signature).unwrap();
        assert_eq!(signature.len(), 64);
        let der = EcdsaSig::from_private_components(
            BigNum::from_slice(&signature[..32]).unwrap(),
            BigNum::from_slice(&signature[32..]).unwrap(),
        )
        .unwrap()
        .to_der()
        .unwrap();
        let mut verifier = Verifier::new(MessageDigest::sha256(), &public_key).unwrap();
        verifier.update(signed.as_bytes()).unwrap();
        assert!(verifier.verify(&der).unwrap());

        let components = ece::EcKeyComponents::new(
            receiver.to_bytes().to_vec(),
            receiver_public.as_bytes().to_vec(),
        );
        let body = request.body().unwrap().as_bytes().unwrap();
        assert_eq!(request.headers()["content-length"], body.len().to_string());
        assert_eq!(ece::decrypt(&components, &auth, body).unwrap(), payload);
        assert!(ece::decrypt(&components, &[4; 16], body).is_err());
        let mut tampered = body.to_vec();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(ece::decrypt(&components, &auth, &tampered).is_err());

        let largest = vec![b'x'; 3052];
        let request = push
            .request(parse_subscription(&sub).unwrap(), &largest, now)
            .unwrap();
        let body = request.body().unwrap().as_bytes().unwrap();
        assert!(body.len() <= 4096);
        assert_eq!(ece::decrypt(&components, &auth, body).unwrap(), largest);
        assert!(push
            .request(parse_subscription(&sub).unwrap(), &[0; 3053], now)
            .is_err());
        assert!(push
            .request(
                parse_subscription(&sub).unwrap(),
                payload,
                UNIX_EPOCH - Duration::from_secs(1),
            )
            .is_err());

        push.subscribe(sub).await.unwrap();
        let reloaded = Push::load(dir.path(), "https://phone.example").unwrap();
        assert_eq!(reloaded.public_key, expected_public);
        assert_eq!(
            config::read_private(&dir.path().join("vapid-key"))
                .unwrap()
                .unwrap(),
            encoded_key
        );
        let persisted: serde_json::Value = serde_json::from_str(
            &config::read_private(&dir.path().join("subscriptions.json"))
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(persisted, saved);
    }

    #[test]
    fn invalid_persisted_signing_key_is_not_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vapid-key");
        let zero_scalar = URL_SAFE_NO_PAD.encode([0; 32]);
        config::create_private(&path, &zero_scalar).unwrap();
        assert!(Push::load(dir.path(), "https://phone.example").is_err());
        assert_eq!(config::read_private(&path).unwrap().unwrap(), zero_scalar);
    }
}
