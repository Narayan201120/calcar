//! Generic-command adapter over plain pipes (PLAN P5).
//!
//! Failure modes first:
//! - `spawn` with `interactive = true` fails with
//!   [`AdapterError::Unsupported`]. The ConPTY gate is red, so there is no
//!   console to attach; plain pipes serve every generic command.
//! - `spawn` with an empty `argv`, or any OS spawn failure, fails with
//!   [`AdapterError::SpawnFailed`] and leaves prior adapter state untouched.
//! - `inject` fails with [`AdapterError::NotRunning`] when no child exists,
//!   and with [`AdapterError::Unsupported`] while a child runs.
//!   [`PlainChild`] stdin is write-once at spawn, so there is no live stdin
//!   handle to write to until the ConPTY path lands.
//! - `respond_approval` always fails with [`AdapterError::Unsupported`]:
//!   generic commands have no approval flow.
//! - `stop` never fails: no child is a no-op, and killing the job tree is
//!   idempotent by job membership.
//! - `drain` never blocks and never fails. It reports whatever the pump
//!   threads collected so far. Bytes past the cap are dropped by the pumps,
//!   a trailing partial stdout line is held back until its newline arrives
//!   or the child exits, and after the single `CommandCompleted` further
//!   drains return nothing, even if a pump delivers straggler bytes later.
//!
//! Event mapping: `spawn` records one `CommandStarted`. Each stdout line
//! rides as [`EventType::Unspecified`] with the raw line as its summary.
//! The common set has no stdout-line type, so lines carry no other meaning.
//! The first drain that observes the exit also emits one
//! [`EventType::ErrorOccurred`] with stderr when stderr is non-empty, then
//! one [`EventType::CommandCompleted`] with the exit code in its summary.
//! Snapshots never carry session ids. Generic commands have no provider
//! session and no resume pointer.

use std::time::Duration;

use calcar_events::{EventType, Provider};
use calcar_pty::{
    plain::{PlainChild, PlainConfig},
    PtyError,
};

use crate::traitdef::{
    AdapterError, AdapterSnapshot, ApprovalDecision, ApprovalOutcome, Capabilities,
    ProviderAdapter, ProviderEvent, SpawnRequest,
};

/// Non-blocking exit poll for `drain` and `snapshot`. Neither method may
/// block, so a zero timeout asks the OS once and returns.
const EXIT_POLL: Duration = Duration::from_millis(0);

/// Generic-command backend: one [`PlainChild`] behind the frozen adapter
/// contract. No approvals, no resume, no session ids. `stop` kills the job
/// tree and `drain` turns buffered pipe output into common events.
pub struct GenericAdapter {
    child: Option<PlainChild>,
    pending_started: Option<ProviderEvent>,
    emitted_lines: usize,
    completed: bool,
}

impl Default for GenericAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl GenericAdapter {
    /// Fresh adapter with no child and no pending events.
    pub fn new() -> Self {
        Self {
            child: None,
            pending_started: None,
            emitted_lines: 0,
            completed: false,
        }
    }

    /// Non-blocking exit check. `None` while the child still runs.
    fn exit_code(child: &PlainChild, cached: Option<u32>) -> Option<u32> {
        cached.or_else(|| child.wait(Some(EXIT_POLL)).ok().flatten())
    }
}

impl ProviderAdapter for GenericAdapter {
    fn name(&self) -> &'static str {
        "generic"
    }

    fn provider(&self) -> Provider {
        Provider::Generic
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            streaming: true,
            interactive_input: false,
            approvals: false,
            file_events: false,
            resume: false,
            stop: true,
            diagnostics: false,
        }
    }

    fn spawn(&mut self, req: SpawnRequest) -> Result<(), AdapterError> {
        if req.interactive {
            return Err(AdapterError::Unsupported);
        }
        let summary = format!("started: {}", req.argv.join(" "));
        let mut config = PlainConfig::new(req.argv.clone());
        config.working_dir = req.working_dir.clone();
        config.env = req.env.clone();
        config.output_cap_bytes = req.output_cap_bytes;
        match PlainChild::spawn(config) {
            Ok(child) => {
                self.child = Some(child);
                self.pending_started = Some(ProviderEvent::new(EventType::CommandStarted, summary));
                self.emitted_lines = 0;
                self.completed = false;
                Ok(())
            }
            Err(error) => Err(map_spawn_error(error)),
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
        if let Some(child) = &self.child {
            child
                .kill()
                .map_err(|error| AdapterError::Io(error.to_string()))?;
        }
        Ok(())
    }

    fn drain(&mut self) -> Vec<ProviderEvent> {
        let mut out = Vec::new();
        if let Some(started) = self.pending_started.take() {
            out.push(started);
        }
        if self.completed {
            return out;
        }
        let Some((stdout, stderr, exit_code)) = self.child.as_ref().map(|child| {
            let snapshot = child.snapshot();
            let exit_code = Self::exit_code(child, snapshot.exit_code);
            (snapshot.stdout, snapshot.stderr, exit_code)
        }) else {
            return out;
        };
        let text = String::from_utf8_lossy(&stdout);
        let lines: Vec<&str> = text.lines().collect();
        let total = lines.len();
        let mut emit_up_to = total;
        if exit_code.is_none() && !text.ends_with('\n') && total > self.emitted_lines {
            emit_up_to = total - 1;
        }
        let from = self.emitted_lines.min(emit_up_to);
        for line in &lines[from..emit_up_to] {
            out.push(ProviderEvent::new(
                EventType::Unspecified,
                (*line).to_string(),
            ));
        }
        self.emitted_lines = emit_up_to;
        if let Some(code) = exit_code {
            if !stderr.is_empty() {
                out.push(ProviderEvent::new(
                    EventType::ErrorOccurred,
                    String::from_utf8_lossy(&stderr).into_owned(),
                ));
            }
            out.push(ProviderEvent::new(
                EventType::CommandCompleted,
                format!("completed with exit code {code}"),
            ));
            self.completed = true;
        }
        out
    }

    fn snapshot(&self) -> AdapterSnapshot {
        match &self.child {
            None => AdapterSnapshot {
                running: false,
                exit_code: None,
                provider_session_id: None,
                resume_pointer: None,
            },
            Some(child) => {
                let exit_code = Self::exit_code(child, child.exit_code());
                AdapterSnapshot {
                    running: exit_code.is_none(),
                    exit_code,
                    provider_session_id: None,
                    resume_pointer: None,
                }
            }
        }
    }
}

/// Spawn-time [`PtyError`] mapping. IO failures stay IO; everything else
/// (empty argv, Windows spawn errors, the off-Windows stub) is a spawn
/// failure.
fn map_spawn_error(error: PtyError) -> AdapterError {
    match error {
        PtyError::Io(io) => AdapterError::Io(io.to_string()),
        other => AdapterError::SpawnFailed(other.to_string()),
    }
}
