//! Codex CLI adapter (PLAN P5).
//!
//! # Failure modes first
//!
//! - `spawn` with `interactive = true` returns [`AdapterError::Unsupported`].
//!   Interactive stdin needs the ConPTY path (`WorkflowPty::write`); the gate
//!   is red, so this adapter only runs over [`PlainChild`] plain pipes.
//! - `spawn` with empty `argv` returns [`AdapterError::SpawnFailed`].
//! - `spawn` while a child is still running returns [`AdapterError::SpawnFailed`]
//!   (`"already running"`). A finished child may be replaced by a new `spawn`.
//! - `spawn` off Windows returns [`AdapterError::SpawnFailed`]: the stub
//!   `PlainChild` refuses with `"plain pipe executor requires Windows"`.
//! - `inject` always returns [`AdapterError::Unsupported`] while a child runs,
//!   [`AdapterError::NotRunning`] with no child. `PlainConfig::input` is
//!   write-once at spawn, then EOF; there is no post-spawn stdin handle on
//!   `PlainChild`, so prompt bytes cannot be delivered after spawn. Prompts
//!   travel in the spawn `argv` (e.g. `codex exec "<prompt>"`) until ConPTY
//!   greens. Returning `Ok` without delivering would lie to core.
//! - `respond_approval` always returns [`AdapterError::Unsupported`]. Codex
//!   approvals need a TTY; non-interactive `exec` either auto-approves per
//!   policy or fails outright, and neither path offers a pipe reply channel.
//!   Approval *requests* are still parsed into `ApprovalRequired` events for
//!   the permission manager, which owns expiry, single-use, and double-accept
//!   rejection. This adapter never resolves approvals itself.
//! - `stop` with no child returns [`AdapterError::NotRunning`]. Otherwise it is
//!   a job-object tree kill and idempotent: stopping twice is `Ok`.
//! - Unparseable output lines are skipped, never fatal. Non-UTF8 bytes are
//!   lossy-converted, never fatal. A missing session marker means
//!   `resume_pointer` stays `None`, not an error.
//!
//! # Marker grammar (byte fixtures)
//!
//! The live path parses `PlainChild::snapshot` stdout/stderr bytes. The same
//! `parse_line` function below serves canned byte strings: the merge E2E
//! spawns a fixture command (e.g. `cmd.exe /C` echoing these lines) and calls
//! `drain`, exercising the identical parse path without the CLI installed.
//!
//! Every line is matched against the `CODEX_` namespace only. Lines without
//! the prefix are plain CLI chatter and skipped. A trailing `\r` (from
//! `cmd.exe` `\r\n` fixtures) is stripped before matching. Grammar:
//!
//! ```text
//! CODEX_SESSION <id>                  -> snapshot session/resume pointer, no event
//! CODEX_START <summary>               -> AgentStarted
//! CODEX_STEP <summary>                -> CommandStarted
//! CODEX_DONE <summary>                -> CommandCompleted
//! CODEX_FILE <path> [note]            -> FileChanged, detail_pointer = <path>
//! CODEX_APPROVAL <req-id> <summary>   -> ApprovalRequired, detail_pointer = <req-id>
//! CODEX_INPUT <summary>               -> InputRequired
//! CODEX_ERROR <summary>               -> ErrorOccurred
//! CODEX_EXIT ok <summary>             -> WorkflowCompleted
//! CODEX_EXIT fail <summary>           -> ErrorOccurred
//! ```
//!
//! Canonical canned fixture:
//!
//! ```text
//! b"CODEX_SESSION sess_03\nCODEX_START scaffolding crate\nCODEX_STEP write Cargo.toml\nCODEX_FILE Cargo.toml created\nCODEX_APPROVAL req_4 run shell\nCODEX_INPUT choose edition\nCODEX_DONE scaffold ready\nCODEX_EXIT ok finished\n"
//! ```
//!
//! Skipped-never-fatal fixture:
//!
//! ```text
//! b"plain chatter\nCODEX_\nCODEX_BOGUS x\nCODEX_EXIT maybe later\n"
//! ```
//!
//! # Resume
//!
//! `capabilities.resume` is true: codex supports resuming a prior session via
//! a `resume <id>` style argv shape (confirm exact spelling against the
//! installed binary at merge; the adapter passes `argv` through opaquely).
//! When the CLI prints `CODEX_SESSION <id>`, `snapshot().resume_pointer` and
//! `provider_session_id` both carry it. Core stores the pointer but never
//! parses it.
//!
//! # Kill semantics
//!
//! `stop` calls `PlainChild::kill`, which terminates the Windows job object:
//! direct child plus grandchildren die. Exit observation is asynchronous; the
//! next `drain` after reaping emits one terminal `WorkflowStopped` event when
//! `stop` was requested, else `WorkflowCompleted` (exit 0) or `ErrorOccurred`
//! (nonzero). The terminal event fires exactly once.

use std::time::Duration;

use calcar_events::{EventType, Provider};
use calcar_pty::plain::{PlainChild, PlainConfig};

use crate::traitdef::{
    AdapterError, AdapterSnapshot, ApprovalDecision, ApprovalOutcome, Capabilities,
    ProviderAdapter, ProviderEvent, SpawnRequest,
};

/// Line namespace for this provider. Keeps codex markers disjoint from the
/// opencode/claude grammars so one CLI's chatter never parses as another's event.
const PREFIX: &str = "CODEX_";

/// Zero-timeout poll used to refresh the cached exit code without blocking.
const EXIT_POLL: Duration = Duration::from_millis(0);

/// Codex backend. One running [`PlainChild`] at most; core sees only
/// [`ProviderEvent`] and [`AdapterSnapshot`].
pub struct CodexAdapter {
    child: Option<PlainChild>,
    stdout_cursor: usize,
    stderr_cursor: usize,
    stdout_tail: Vec<u8>,
    stderr_tail: Vec<u8>,
    provider_session_id: Option<String>,
    stop_requested: bool,
    terminal_emitted: bool,
}

impl Default for CodexAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl CodexAdapter {
    pub fn new() -> Self {
        Self {
            child: None,
            stdout_cursor: 0,
            stderr_cursor: 0,
            stdout_tail: Vec::new(),
            stderr_tail: Vec::new(),
            provider_session_id: None,
            stop_requested: false,
            terminal_emitted: false,
        }
    }

    fn reset(&mut self) {
        self.child = None;
        self.stdout_cursor = 0;
        self.stderr_cursor = 0;
        self.stdout_tail.clear();
        self.stderr_tail.clear();
        self.provider_session_id = None;
        self.stop_requested = false;
        self.terminal_emitted = false;
    }

    fn is_running(&self) -> bool {
        match self.child.as_ref() {
            None => false,
            Some(child) => {
                let _ = child.wait(Some(EXIT_POLL));
                child.exit_code().is_none()
            }
        }
    }
}

/// Map one grammar line to events/session. Never fails: anything outside the
/// grammar is skipped by returning without pushing.
fn parse_line(line: &str, events: &mut Vec<ProviderEvent>, session: &mut Option<String>) {
    let rest = match line.strip_prefix(PREFIX) {
        Some(rest) => rest,
        None => return,
    };
    let (verb, payload) = match rest.find(' ') {
        Some(idx) => (&rest[..idx], rest[idx + 1..].trim_start()),
        None => (rest, ""),
    };
    match verb {
        "START" => events.push(ProviderEvent::new(EventType::AgentStarted, payload)),
        "STEP" => events.push(ProviderEvent::new(EventType::CommandStarted, payload)),
        "DONE" => events.push(ProviderEvent::new(EventType::CommandCompleted, payload)),
        "FILE" => {
            let mut event = ProviderEvent::new(EventType::FileChanged, payload);
            event.detail_pointer = payload.split_whitespace().next().map(str::to_string);
            events.push(event);
        }
        "APPROVAL" => {
            let (id, summary) = match payload.find(' ') {
                Some(idx) => (&payload[..idx], payload[idx + 1..].trim_start()),
                None => (payload, ""),
            };
            let mut event = ProviderEvent::new(EventType::ApprovalRequired, summary);
            if !id.is_empty() {
                event.detail_pointer = Some(id.to_string());
            }
            events.push(event);
        }
        "INPUT" => events.push(ProviderEvent::new(EventType::InputRequired, payload)),
        "ERROR" => events.push(ProviderEvent::new(EventType::ErrorOccurred, payload)),
        "EXIT" => {
            let (status, summary) = match payload.find(' ') {
                Some(idx) => (&payload[..idx], payload[idx + 1..].trim_start()),
                None => (payload, ""),
            };
            match status {
                "ok" => events.push(ProviderEvent::new(EventType::WorkflowCompleted, summary)),
                "fail" => events.push(ProviderEvent::new(EventType::ErrorOccurred, summary)),
                _ => {}
            }
        }
        "SESSION" => {
            let id = payload.trim();
            if !id.is_empty() {
                *session = Some(id.to_string());
            }
        }
        _ => {}
    }
}

/// Feed newly collected stream bytes through the grammar. Holds back an
/// unterminated trailing fragment until a newline arrives or the child exits.
fn consume(
    bytes: &[u8],
    cursor: &mut usize,
    tail: &mut Vec<u8>,
    finished: bool,
    events: &mut Vec<ProviderEvent>,
    session: &mut Option<String>,
) {
    let start = (*cursor).min(bytes.len());
    tail.extend_from_slice(&bytes[start..]);
    *cursor = bytes.len();
    let mut lines: Vec<String> = Vec::new();
    let mut last = 0;
    for (idx, &byte) in tail.iter().enumerate() {
        if byte == b'\n' {
            lines.push(String::from_utf8_lossy(&tail[last..idx]).into_owned());
            last = idx + 1;
        }
    }
    if finished {
        if last < tail.len() {
            lines.push(String::from_utf8_lossy(&tail[last..]).into_owned());
        }
        tail.clear();
    } else {
        tail.drain(..last);
    }
    for line in &lines {
        parse_line(line.trim_end_matches('\r'), events, session);
    }
}

impl ProviderAdapter for CodexAdapter {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn provider(&self) -> Provider {
        Provider::Codex
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            streaming: true,
            interactive_input: false,
            approvals: false,
            file_events: true,
            resume: true,
            stop: true,
            diagnostics: true,
        }
    }

    fn spawn(&mut self, req: SpawnRequest) -> Result<(), AdapterError> {
        if req.interactive {
            return Err(AdapterError::Unsupported);
        }
        if req.argv.is_empty() {
            return Err(AdapterError::SpawnFailed("argv is empty".into()));
        }
        if self.is_running() {
            return Err(AdapterError::SpawnFailed("already running".into()));
        }
        self.reset();
        let config = PlainConfig {
            argv: req.argv,
            working_dir: req.working_dir,
            env: req.env,
            input: None,
            output_cap_bytes: req.output_cap_bytes,
        };
        match PlainChild::spawn(config) {
            Ok(child) => {
                self.child = Some(child);
                Ok(())
            }
            Err(err) => Err(AdapterError::SpawnFailed(err.to_string())),
        }
    }

    fn inject(&mut self, _input: &[u8]) -> Result<(), AdapterError> {
        if self.child.is_none() {
            return Err(AdapterError::NotRunning);
        }
        Err(AdapterError::Unsupported)
    }

    fn respond_approval(
        &mut self,
        _request_id: &str,
        _decision: ApprovalDecision,
    ) -> Result<ApprovalOutcome, AdapterError> {
        Err(AdapterError::Unsupported)
    }

    fn stop(&mut self) -> Result<(), AdapterError> {
        match self.child.as_ref() {
            None => Err(AdapterError::NotRunning),
            Some(child) => {
                child
                    .kill()
                    .map_err(|err| AdapterError::Io(err.to_string()))?;
                self.stop_requested = true;
                Ok(())
            }
        }
    }

    fn drain(&mut self) -> Vec<ProviderEvent> {
        let mut events = Vec::new();
        let child = match self.child.as_ref() {
            None => return events,
            Some(child) => child,
        };
        let _ = child.wait(Some(EXIT_POLL));
        let finished = child.exit_code().is_some();
        let snapshot = child.snapshot();
        consume(
            &snapshot.stdout,
            &mut self.stdout_cursor,
            &mut self.stdout_tail,
            finished,
            &mut events,
            &mut self.provider_session_id,
        );
        consume(
            &snapshot.stderr,
            &mut self.stderr_cursor,
            &mut self.stderr_tail,
            finished,
            &mut events,
            &mut self.provider_session_id,
        );
        if finished && !self.terminal_emitted {
            self.terminal_emitted = true;
            if self.stop_requested {
                events.push(ProviderEvent::new(EventType::WorkflowStopped, "stopped"));
            } else {
                match child.exit_code() {
                    Some(0) => {
                        events.push(ProviderEvent::new(EventType::WorkflowCompleted, "exit 0"))
                    }
                    Some(code) => events.push(ProviderEvent::new(
                        EventType::ErrorOccurred,
                        format!("exit {code}"),
                    )),
                    None => {}
                }
            }
        }
        events
    }

    fn snapshot(&self) -> AdapterSnapshot {
        match self.child.as_ref() {
            None => AdapterSnapshot {
                running: false,
                exit_code: None,
                provider_session_id: self.provider_session_id.clone(),
                resume_pointer: self.provider_session_id.clone(),
            },
            Some(child) => {
                let _ = child.wait(Some(EXIT_POLL));
                let exit_code = child.exit_code();
                AdapterSnapshot {
                    running: exit_code.is_none(),
                    exit_code,
                    provider_session_id: self.provider_session_id.clone(),
                    resume_pointer: self.provider_session_id.clone(),
                }
            }
        }
    }
}
