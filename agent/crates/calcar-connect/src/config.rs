//! Server config plus the bearer token file.
//!
//! Failure modes first:
//! 1. Missing config file, malformed line, missing required key, or a port
//!    outside 1..=65535 fails [`ConnectConfig::load`] before any socket
//!    opens. Nothing listens half-configured.
//! 2. The token file is read at [`ConnectServer`](crate::ConnectServer)
//!    construction, not per request. A missing, unreadable, or
//!    whitespace-only token file fails startup. Rotation needs a restart;
//!    a restart is cheap and avoids in-flight requests straddling two
//!    tokens.
//! 3. Unknown `key=value` lines are ignored so older binaries tolerate
//!    newer configs. A typo in a REQUIRED key surfaces as a missing-key
//!    error, which names the key (config keys are not secrets).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use thiserror::Error;

/// Startup failures. No variants carry file contents: the token file is
/// never read into an error string.
#[derive(Debug, Error)]
pub enum ConnectError {
    #[error("config io: {0}")]
    Io(#[from] std::io::Error),
    #[error("config {path}: {problem}")]
    Config { path: String, problem: String },
    #[error("http bind failed on {addr}: {detail}")]
    Bind { addr: String, detail: String },
    #[error("storage: {0}")]
    Storage(#[from] calcar_storage::StorageError),
    #[error("lifecycle: {0}")]
    Lifecycle(#[from] calcar_workflow::LifecycleError),
}

/// Static description of this managed computer plus where its truth lives.
#[derive(Debug, Clone)]
pub struct ConnectConfig {
    pub port: u16,
    pub token_file: PathBuf,
    pub db_path: PathBuf,
    pub computer_id: String,
    pub display_name: String,
    pub owner_device_id: String,
    pub pubkey_b64: String,
    pub fingerprint: String,
    pub cpu: String,
    pub ram: String,
    pub gpu: String,
    pub disk: String,
    pub exec_timeout_secs: u64,
}

impl ConnectConfig {
    /// Parse a `key=value` file (`#` comments, blank lines skipped).
    /// Required: `port`, `token_file`, `db_path`, `computer_id`.
    /// Optional with defaults: `display_name` (falls back to
    /// `computer_id`), `exec_timeout_secs` (30), and the sysinfo / device
    /// identity strings (empty means unprovisioned, served blank rather
    /// than guessed).
    pub fn load(path: &Path) -> Result<Self, ConnectError> {
        let text = std::fs::read_to_string(path)?;
        let mut map = BTreeMap::new();
        for (index, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = line.split_once('=').ok_or_else(|| ConnectError::Config {
                path: path.display().to_string(),
                problem: format!("line {} is not key=value", index + 1),
            })?;
            map.insert(key.trim().to_string(), value.trim().to_string());
        }
        let required = |key: &str| -> Result<String, ConnectError> {
            match map.get(key) {
                Some(value) if !value.is_empty() => Ok(value.clone()),
                _ => Err(ConnectError::Config {
                    path: path.display().to_string(),
                    problem: format!("missing required key {key}"),
                }),
            }
        };
        let optional = |key: &str| -> String { map.get(key).cloned().unwrap_or_default() };
        let port: u16 = required("port")?
            .parse()
            .ok()
            .filter(|port| *port >= 1)
            .ok_or_else(|| ConnectError::Config {
                path: path.display().to_string(),
                problem: "port must be 1..=65535".to_string(),
            })?;
        let exec_timeout_secs = optional("exec_timeout_secs")
            .parse::<u64>()
            .ok()
            .filter(|secs| *secs >= 1)
            .unwrap_or(30);
        let computer_id = required("computer_id")?;
        let display_name = match optional("display_name") {
            empty if empty.is_empty() => computer_id.clone(),
            name => name,
        };
        Ok(Self {
            port,
            token_file: PathBuf::from(required("token_file")?),
            db_path: PathBuf::from(required("db_path")?),
            computer_id,
            display_name,
            owner_device_id: optional("owner_device_id"),
            pubkey_b64: optional("pubkey_b64"),
            fingerprint: optional("fingerprint"),
            cpu: optional("cpu"),
            ram: optional("ram"),
            gpu: optional("gpu"),
            disk: optional("disk"),
            exec_timeout_secs,
        })
    }

    /// Directory holding the registry sidecar and PTY tail files.
    pub fn state_dir(&self) -> PathBuf {
        self.db_path
            .parent()
            .map_or_else(|| PathBuf::from("."), std::path::Path::to_path_buf)
    }
}

/// Read the bearer token: whole file, trimmed. Empty after trim is a
/// config error, never an empty token (an empty token would match
/// nothing, but failing loud beats serving 401 to everyone silently).
pub fn read_token(path: &Path) -> Result<String, ConnectError> {
    let raw = std::fs::read_to_string(path)?;
    let token = raw.trim().to_string();
    if token.is_empty() {
        return Err(ConnectError::Config {
            path: path.display().to_string(),
            problem: "token file is empty".to_string(),
        });
    }
    Ok(token)
}
