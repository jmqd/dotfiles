use crate::config::{self, Config, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use webauthn_rs::prelude::*;

pub const CEREMONY_AGE: Duration = Duration::from_secs(300);
const MAX_RECORDS: usize = 128;
const MAX_FILE_BYTES: u64 = 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub name: String,
    pub origin: String,
    pub passkey: Passkey,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CounterState {
    origin: String,
    cred_id: CredentialID,
    public_key: COSEKey,
    counter: u32,
}

struct Ceremony<T> {
    login: String,
    deadline: Instant,
    state: T,
}

pub struct Auth {
    webauthn: Webauthn,
    origin: String,
    dir: PathBuf,
    records: Vec<Record>,
    authentication: HashMap<String, Ceremony<PasskeyAuthentication>>,
    registration: HashMap<String, Ceremony<(String, PasskeyRegistration)>>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Enrollment {
    name: String,
    origin: String,
    secret: String,
    expires: u64,
}

fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn output_path(dir: &Path, name: &str) -> Result<PathBuf> {
    if !valid_name(name) {
        return Err(
            "enrollment name must be 1–64 ASCII letters, digits, hyphens or underscores".into(),
        );
    }
    let path = dir.join(format!("enrolled-{name}.json"));
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
        Err(error) => Err(error.into()),
        Ok(_) => Err("enrollment output already exists; choose a new name".into()),
    }
}

fn enrollment_lock(dir: &Path) -> Result<File> {
    let path = dir.join("enrollment.lock");
    config::read_private(&path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    fs2::FileExt::lock_exclusive(&file)?;
    Ok(file)
}

pub fn enroll(config: &Config, name: &str) -> Result<()> {
    if !valid_name(name) {
        return Err(
            "enrollment name must be 1–64 ASCII letters, digits, hyphens or underscores".into(),
        );
    }
    config::private_directory(&config.dir)?;
    let _lock = enrollment_lock(&config.dir)?;
    let output = output_path(&config.dir, name)?;
    let pending = Enrollment {
        name: name.to_owned(),
        origin: config.origin.clone(),
        secret: config::random_secret(),
        expires: now()? + CEREMONY_AGE.as_secs(),
    };
    config::save_private(
        &config.dir.join("enrollment.json"),
        &serde_json::to_string(&pending)?,
    )?;
    println!("{}/omp/#enroll={}", config.origin, pending.secret);
    println!("Public credential output: {}", output.display());
    println!("Authorization expires in 5 minutes and permits one registration attempt. Enrollment does not enable login; configure the public record and restart.");
    Ok(())
}

fn hardware_credential(passkey: &Passkey) -> Result<Credential> {
    let cred: Credential = passkey.clone().into();
    if !cred.user_verified || cred.backup_eligible || cred.backup_state {
        return Err("a user-verified, non-backup-eligible security key is required".into());
    }
    Ok(cred)
}

impl Auth {
    pub fn load(config: &Config) -> Result<Self> {
        let origin = Url::parse(&config.origin)?;
        let webauthn =
            WebauthnBuilder::new(origin.host_str().ok_or("missing RP hostname")?, &origin)?
                .rp_name("OMP Phone")
                .timeout(CEREMONY_AGE)
                .build()?;
        let mut records: Vec<Record> = match &config.credentials_file {
            None => Vec::new(),
            Some(path) => match File::open(path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
                Err(error) => return Err(error.into()),
                Ok(file) => {
                    if !file.metadata()?.is_file() || file.metadata()?.len() > MAX_FILE_BYTES {
                        return Err(
                            "credential inventory must be a regular file of at most 1 MiB".into(),
                        );
                    }
                    let mut data = Vec::new();
                    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut data)?;
                    if data.len() as u64 > MAX_FILE_BYTES {
                        return Err("credential inventory too large".into());
                    }
                    serde_json::from_slice(&data)?
                }
            },
        };
        if records.len() > MAX_RECORDS {
            return Err("too many configured credentials".into());
        }
        let mut ids = HashSet::new();
        for record in &records {
            let url = Url::parse(&record.origin)?;
            if !valid_name(&record.name)
                || url.origin().ascii_serialization() != record.origin
                || !matches!(url.scheme(), "http" | "https")
                || url.host_str().is_none()
            {
                return Err("invalid credential inventory name or origin".into());
            }
            hardware_credential(&record.passkey)?;
            if !ids.insert(record.passkey.cred_id().clone()) {
                return Err("duplicate credential ID in inventory".into());
            }
        }
        records.retain(|record| record.origin == config.origin);
        if let Some(data) = config::read_private(&config.dir.join("credential-state.json"))? {
            let states: Vec<CounterState> = serde_json::from_str(&data)?;
            if states.len() > MAX_RECORDS {
                return Err("too many persisted credential states".into());
            }
            let mut ids = HashSet::new();
            for state in states {
                if !ids.insert((state.origin.clone(), state.cred_id.clone())) {
                    return Err("duplicate persisted credential state".into());
                }
                // Runtime data can only raise the counter of an identical configured key.
                // It cannot add trust, replace key material, or lower the inventory baseline.
                if let Some(record) = records.iter_mut().find(|record| {
                    record.origin == state.origin && record.passkey.cred_id() == &state.cred_id
                }) {
                    if serde_json::to_value(record.passkey.get_public_key())?
                        == serde_json::to_value(&state.public_key)?
                    {
                        let mut cred: Credential = record.passkey.clone().into();
                        cred.counter = cred.counter.max(state.counter);
                        record.passkey = cred.into();
                    }
                }
            }
        }
        Ok(Self {
            webauthn,
            origin: config.origin.clone(),
            dir: config.dir.clone(),
            records,
            authentication: HashMap::new(),
            registration: HashMap::new(),
        })
    }

    fn prune(&mut self) {
        let now = Instant::now();
        self.authentication.retain(|_, c| c.deadline > now);
        self.registration.retain(|_, c| c.deadline > now);
    }

    pub fn start_authentication(
        &mut self,
        login: &str,
    ) -> Result<(RequestChallengeResponse, String)> {
        self.prune();
        if self.records.is_empty() {
            return Err("no security keys configured for this service".into());
        }
        if self.authentication.len() >= 32 {
            return Err("too many authentication attempts; wait five minutes".into());
        }
        let keys: Vec<_> = self
            .records
            .iter()
            .map(|record| record.passkey.clone())
            .collect();
        let (options, state) = self.webauthn.start_passkey_authentication(&keys)?;
        let cookie = config::random_secret();
        self.authentication.insert(
            cookie.clone(),
            Ceremony {
                login: login.into(),
                deadline: Instant::now() + CEREMONY_AGE,
                state,
            },
        );
        Ok((options, cookie))
    }

    pub fn finish_authentication(
        &mut self,
        login: &str,
        cookie: &str,
        response: &PublicKeyCredential,
    ) -> Result<()> {
        self.prune();
        let ceremony = self
            .authentication
            .remove(cookie)
            .ok_or("authentication challenge expired or missing")?;
        if ceremony.login != login {
            return Err("authentication identity changed".into());
        }
        let result = self
            .webauthn
            .finish_passkey_authentication(response, &ceremony.state)?;
        if !result.user_verified() || result.backup_eligible() || result.backup_state() {
            return Err(
                "user verification on a non-backup-eligible security key is required".into(),
            );
        }
        let index = self
            .records
            .iter()
            .position(|record| record.passkey.cred_id() == result.cred_id())
            .ok_or("unknown credential")?;
        let current: Credential = self.records[index].passkey.clone().into();
        // Check against live state too: concurrent challenges contain older counters.
        if (current.counter != 0 || result.counter() != 0) && result.counter() <= current.counter {
            return Err("security key counter did not advance".into());
        }
        let mut updated = self.records[index].passkey.clone();
        updated
            .update_credential(&result)
            .ok_or("credential mismatch")?;
        let states: Vec<_> = self
            .records
            .iter()
            .enumerate()
            .map(|(i, record)| {
                let cred: Credential = (if i == index {
                    updated.clone()
                } else {
                    record.passkey.clone()
                })
                .into();
                CounterState {
                    origin: record.origin.clone(),
                    cred_id: cred.cred_id,
                    public_key: cred.cred,
                    counter: cred.counter,
                }
            })
            .collect();
        config::save_private(
            &self.dir.join("credential-state.json"),
            &serde_json::to_string(&states)?,
        )?;
        self.records[index].passkey = updated;
        Ok(())
    }

    pub fn start_registration(
        &mut self,
        login: &str,
        secret: &str,
    ) -> Result<(CreationChallengeResponse, String)> {
        self.prune();
        if self.registration.len() >= 8 {
            return Err("too many registration attempts; wait five minutes".into());
        }
        let _lock = enrollment_lock(&self.dir)?;
        let path = self.dir.join("enrollment.json");
        let data =
            config::read_private(&path)?.ok_or("no pending local enrollment authorization")?;
        let pending: Enrollment = serde_json::from_str(&data)?;
        if pending.expires <= now()?
            || pending.origin != self.origin
            || !bool::from(pending.secret.as_bytes().ct_eq(secret.as_bytes()))
        {
            return Err("invalid or expired enrollment authorization".into());
        }
        output_path(&self.dir, &pending.name)?;
        let excluded = self
            .records
            .iter()
            .map(|record| record.passkey.cred_id().clone())
            .collect();
        let (mut options, state) = self.webauthn.start_passkey_registration(
            Uuid::new_v4(),
            &pending.name,
            &pending.name,
            Some(excluded),
        )?;
        if let Some(selection) = options.public_key.authenticator_selection.as_mut() {
            selection.authenticator_attachment = Some(AuthenticatorAttachment::CrossPlatform);
        } else {
            return Err("missing authenticator selection".into());
        }
        // Consume only a valid authorization, before returning options to the browser.
        fs::remove_file(path)?;
        File::open(&self.dir)?.sync_all()?;
        let cookie = config::random_secret();
        self.registration.insert(
            cookie.clone(),
            Ceremony {
                login: login.into(),
                deadline: Instant::now() + CEREMONY_AGE,
                state: (pending.name, state),
            },
        );
        Ok((options, cookie))
    }

    pub fn finish_registration(
        &mut self,
        login: &str,
        cookie: &str,
        response: &RegisterPublicKeyCredential,
    ) -> Result<String> {
        self.prune();
        let ceremony = self
            .registration
            .remove(cookie)
            .ok_or("registration challenge expired or missing")?;
        if ceremony.login != login {
            return Err("registration identity changed".into());
        }
        let (name, state) = ceremony.state;
        let path = output_path(&self.dir, &name)?;
        let passkey = self
            .webauthn
            .finish_passkey_registration(response, &state)?;
        hardware_credential(&passkey)?;
        if self
            .records
            .iter()
            .any(|record| record.passkey.cred_id() == passkey.cred_id())
        {
            return Err("credential already configured".into());
        }
        let record = Record {
            name: name.clone(),
            origin: self.origin.clone(),
            passkey,
        };
        config::create_private(&path, &serde_json::to_string_pretty(&record)?)?;
        File::open(&self.dir)?.sync_all()?;
        Ok(name)
    }
}
