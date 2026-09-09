use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{rngs::SysRng, TryRng};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use url::Url;

pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T, E = Error> = std::result::Result<T, E>;

pub struct Config {
    pub dir: PathBuf,
    pub port: u16,
    pub origin: String,
    pub origins: Vec<String>,
    pub hosts: Vec<String>,
    pub allowed_tailnet_users: Vec<String>,
    pub tailnet_capability: String,
    pub secure: bool,
    pub hostname: String,
    pub credentials_file: Option<PathBuf>,
}

impl Config {
    pub fn load() -> Result<Self> {
        let dir = match env::var_os("OMP_PHONE_STATE_DIR") {
            Some(path) => PathBuf::from(path),
            None => match env::var_os("XDG_STATE_HOME") {
                Some(path) => PathBuf::from(path).join("omp-phone"),
                None => PathBuf::from(env::var_os("HOME").ok_or("HOME is not set")?)
                    .join(".local/state/omp-phone"),
            },
        };
        if !dir.is_absolute() {
            return Err("state directory must be absolute".into());
        }
        let credentials_file = env::var_os("OMP_PHONE_CREDENTIALS_FILE").map(PathBuf::from);
        if credentials_file
            .as_ref()
            .is_some_and(|path| !path.is_absolute())
        {
            return Err("OMP_PHONE_CREDENTIALS_FILE must be absolute".into());
        }
        let port = env::var("OMP_PHONE_PORT")
            .unwrap_or_else(|_| "8787".into())
            .parse::<u16>()?;
        if port == 0 {
            return Err("OMP_PHONE_PORT must not be zero".into());
        }
        let raw = env::var("OMP_PHONE_PUBLIC_URL")
            .unwrap_or_else(|_| format!("http://localhost:{port}/omp/"));
        let url = Url::parse(&raw)?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !matches!(url.path(), "/omp" | "/omp/")
        {
            return Err(
                "OMP_PHONE_PUBLIC_URL must be an http(s) URL at /omp/ without credentials, query or fragment".into(),
            );
        }
        if url.scheme() == "http" && !matches!(url.host_str(), Some("localhost" | "127.0.0.1")) {
            return Err("external OMP_PHONE_PUBLIC_URL requires HTTPS".into());
        }
        if url.scheme() == "https" && !url.host_str().is_some_and(|host| host.ends_with(".ts.net"))
        {
            return Err("HTTPS mode requires a Tailscale .ts.net hostname".into());
        }
        let allowed_tailnet_users: Vec<String> = env::var("OMP_PHONE_TAILNET_USERS")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|user| !user.is_empty())
            .map(str::to_owned)
            .collect();
        let tailnet_capability = env::var("OMP_PHONE_TAILNET_CAPABILITY").unwrap_or_default();
        if url.scheme() == "https"
            && (allowed_tailnet_users.is_empty() || tailnet_capability.is_empty())
        {
            return Err(
                "HTTPS mode requires OMP_PHONE_TAILNET_USERS and OMP_PHONE_TAILNET_CAPABILITY"
                    .into(),
            );
        }
        let origin = url.origin().ascii_serialization();
        let mut origins = vec![origin.clone()];
        if url.scheme() == "http" && matches!(url.host_str(), Some("localhost" | "127.0.0.1")) {
            for host in ["localhost", "127.0.0.1"] {
                origins.push(
                    Url::parse(&format!("http://{host}:{port}"))?
                        .origin()
                        .ascii_serialization(),
                );
            }
        }
        origins.sort();
        origins.dedup();
        let mut hosts: Vec<String> = origins
            .iter()
            .map(|origin| origin.split_once("://").unwrap().1.to_owned())
            .collect();
        hosts.extend([format!("127.0.0.1:{port}"), format!("localhost:{port}")]);
        let hostname = env::var("OMP_PHONE_HOSTNAME")
            .ok()
            .or_else(|| {
                hostname::get()
                    .ok()
                    .map(|name| name.to_string_lossy().into_owned())
            })
            .unwrap_or_else(|| "OMP".into())
            .trim()
            .chars()
            .take(128)
            .collect();
        Ok(Self {
            dir,
            port,
            secure: url.scheme() == "https",
            origin,
            origins,
            allowed_tailnet_users,
            tailnet_capability,
            hosts,
            hostname,
            credentials_file,
        })
    }
}

/// Only the same OS user can reach extension control. This socket is never
/// mounted on the HTTP router, so neither Serve nor Funnel can forward to it.
pub struct ExtensionListener {
    pub listener: tokio::net::UnixListener,
    path: PathBuf,
}

impl ExtensionListener {
    pub fn bind(dir: &Path) -> Result<Self> {
        let path = dir.join("extension.sock");
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_socket() => fs::remove_file(&path)?,
            Ok(_) => return Err("extension.sock exists and is not a Unix socket".into()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let listener = tokio::net::UnixListener::bind(&path)?;
        let bound = Self { listener, path };
        fs::set_permissions(&bound.path, fs::Permissions::from_mode(0o600))?;
        Ok(bound)
    }
}

impl Drop for ExtensionListener {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn random_secret() -> String {
    let mut bytes = [0; 32];
    SysRng
        .try_fill_bytes(&mut bytes)
        .expect("system random source unavailable");
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn private_directory(path: &Path) -> Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("state directory must be a real directory".into());
    }
    // Refuse sharing someone else's state, even when the directory is writable.
    let home_owner = fs::metadata(env::var_os("HOME").ok_or("HOME is not set")?)?.uid();
    if metadata.uid() != home_owner {
        return Err("state directory has a different owner".into());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn lock_state(dir: &Path) -> Result<File> {
    let path = dir.join("server.lock");
    read_private(&path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    fs2::FileExt::try_lock_exclusive(&file)
        .map_err(|_| "another companion is using this state directory")?;
    Ok(file)
}

pub fn read_private(path: &Path) -> Result<Option<String>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err("state file must be a regular private (0600) file".into());
    }
    if metadata.len() > 1024 * 1024 {
        return Err("state file exceeds 1 MiB".into());
    }
    let mut text = String::new();
    File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_string(&mut text)?;
    if text.len() > 1024 * 1024 {
        return Err("state file exceeds 1 MiB".into());
    }
    Ok(Some(text))
}

pub fn create_private(path: &Path, value: &str) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(value.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

pub fn save_private(path: &Path, value: &str) -> Result<()> {
    let temp = path.with_extension(format!("tmp-{}", random_secret()));
    let result = (|| {
        create_private(&temp, value)?;
        fs::rename(&temp, path)?;
        File::open(path.parent().ok_or("state file has no parent")?)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}
