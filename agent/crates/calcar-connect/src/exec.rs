//! Generic-command execution over [`PlainChild`](calcar_pty::plain::PlainChild).
//!
//! Failure modes first:
//! 1. An empty command body is refused before spawn. There is no
//!    interactive stdin on this path (stdin is closed), so a command that
//!    blocks on input hits the timeout instead of hanging the server.
//! 2. The wait is bounded by the configured timeout. On expiry the whole
//!    job tree is killed (grandchildren included, by job membership) and
//!    the caller reports 504. The kill-then-drop sequence is idempotent.
//! 3. Off Windows, spawn always fails: the caller reports 500, never a
//!    fake success. Generic execution is a Windows-agent capability.
//! 4. Output is capped twice: per-stream pipe caps in `PlainChild`, then
//!    the tail file keeps the newest [`TAIL_FILE_BYTES`] (terminal byte
//!    budget from `caps.dart`). The event ring stores the tail path only,
//!    never the log bytes (PRD 29/37: no transcripts in the database).

use std::path::{Path, PathBuf};
use std::time::Duration;

use calcar_pty::plain::{PlainChild, PlainConfig};
use thiserror::Error;

/// Newest output bytes kept in the per-input tail file. Mirrors
/// `kTerminalByteCap` so the phone's terminal tab and the agent agree.
pub const TAIL_FILE_BYTES: usize = 256 * 1024;

/// How long `join` waits for inherited pipe ends after exit.
const PUMP_GRACE: Duration = Duration::from_secs(2);

#[derive(Debug, Error)]
pub enum ExecError {
    #[error("spawn failed: {0}")]
    Spawn(String),
    #[error("command timed out and was killed")]
    Timeout,
    #[error("output collection failed: {0}")]
    Join(String),
    #[error("tail file io: {0}")]
    Io(#[from] std::io::Error),
}

/// Bounded run of one generic command.
#[derive(Debug)]
pub struct ExecOutcome {
    pub exit_code: u32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub truncated: bool,
}

/// Run `body` as `cmd.exe /C body` with no interactive stdin, waiting at
/// most `timeout`. Timeout kills the job tree before returning.
pub fn run_generic(body: &str, timeout: Duration) -> Result<ExecOutcome, ExecError> {
    if body.trim().is_empty() {
        return Err(ExecError::Spawn(
            "command body must not be empty".to_string(),
        ));
    }
    let child = PlainChild::spawn(PlainConfig::new(vec![
        "cmd.exe".to_string(),
        "/C".to_string(),
        body.to_string(),
    ]))
    .map_err(|error| ExecError::Spawn(error.to_string()))?;
    match child
        .wait(Some(timeout))
        .map_err(|error| ExecError::Spawn(error.to_string()))?
    {
        Some(_) => {
            let output = child
                .join(PUMP_GRACE)
                .map_err(|error| ExecError::Join(error.to_string()))?;
            Ok(ExecOutcome {
                exit_code: output.exit_code.unwrap_or(1),
                stdout: output.stdout,
                stderr: output.stderr,
                truncated: output.truncated,
            })
        }
        None => {
            let _ = child.kill();
            drop(child);
            Err(ExecError::Timeout)
        }
    }
}

/// Input ids double as tail-file names, so they are restricted to a safe
/// alphabet. Rejects path separators, `..`, and overlong ids.
pub fn check_input_id(input_id: &str) -> bool {
    if input_id.is_empty() || input_id.len() > 128 {
        return false;
    }
    input_id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
}

/// Write the newest bytes of the run into
/// `<state_dir>/tails/<workflow_id>-<input_id>.log`, returning the path
/// string stored as the event `detail_pointer`. Keeps the tail (newest
/// wins, like the phone caps); cutting happens on a char boundary and
/// reports whether anything was cut.
pub fn write_tail(
    state_dir: &Path,
    workflow_id: &str,
    input_id: &str,
    outcome: &ExecOutcome,
) -> std::io::Result<(String, bool)> {
    let dir = state_dir.join("tails");
    std::fs::create_dir_all(&dir)?;
    let path: PathBuf = dir.join(format!("{workflow_id}-{input_id}.log"));
    let mut text = String::from_utf8_lossy(&outcome.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&outcome.stderr);
    if !stderr.is_empty() {
        text.push_str("\n--- stderr ---\n");
        text.push_str(&stderr);
    }
    let (kept, cut) = tail_bytes(&text, TAIL_FILE_BYTES);
    let file_cut = cut || outcome.truncated;
    let mut body = String::new();
    if file_cut {
        body.push_str("...truncated\n");
    }
    body.push_str(&kept);
    std::fs::write(&path, body)?;
    Ok((path.to_string_lossy().into_owned(), file_cut))
}

/// Newest `max_bytes` of `text` on a char boundary, plus whether a cut
/// happened.
fn tail_bytes(text: &str, max_bytes: usize) -> (String, bool) {
    let bytes = text.as_bytes();
    if bytes.len() <= max_bytes {
        return (text.to_string(), false);
    }
    let mut start = bytes.len() - max_bytes;
    while start < bytes.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    (text[start..].to_string(), true)
}
