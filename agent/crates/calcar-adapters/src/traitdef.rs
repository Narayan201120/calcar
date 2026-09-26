//! The frozen adapter contract. Core calls these methods and matches these
//! errors. Provider quirks stay in the adapter files, never here.
use calcar_events::{EventType, Provider};
use thiserror::Error;

/// What one provider backend can do. Independent flags, not a sum: a
/// provider can stream without approvals, or stop without resume.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    pub streaming: bool,
    pub interactive_input: bool,
    pub approvals: bool,
    pub file_events: bool,
    pub resume: bool,
    pub stop: bool,
    pub diagnostics: bool,
}

/// One parsed provider output. Core stamps ids and sequence numbers;
/// adapters never mint them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderEvent {
    pub event_type: EventType,
    pub summary: String,
    pub detail_pointer: Option<String>,
}

impl ProviderEvent {
    pub fn new(event_type: EventType, summary: impl Into<String>) -> Self {
        Self {
            event_type,
            summary: summary.into(),
            detail_pointer: None,
        }
    }
}

/// Owner verdict on one approval request. Single resolve wins downstream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalDecision {
    Allow,
    Reject,
}

/// What applying a verdict did. Duplicate and Expired are terminal
/// answers, not errors: the request is already settled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalOutcome {
    Applied,
    Duplicate,
    Expired,
    Unknown,
}

/// Every failure an adapter can report. Variants are exhaustive on
/// purpose: a new failure mode must add a variant, and every `match`
/// on this type then fails to compile until handled.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum AdapterError {
    #[error("spawn failed: {0}")]
    SpawnFailed(String),
    #[error("no running child")]
    NotRunning,
    #[error("adapter does not support this call")]
    Unsupported,
    #[error("provider output unparseable: {0}")]
    ParseError(String),
    #[error("io error: {0}")]
    Io(String),
}

/// How to start one provider child. `interactive` asks for the ConPTY
/// path; plain pipes serve every request until that gate greens.
pub struct SpawnRequest {
    pub argv: Vec<String>,
    pub working_dir: Option<std::path::PathBuf>,
    pub env: Vec<(String, String)>,
    pub interactive: bool,
    pub output_cap_bytes: usize,
}

impl SpawnRequest {
    pub fn new(argv: Vec<String>) -> Self {
        Self {
            argv,
            working_dir: None,
            env: Vec::new(),
            interactive: false,
            output_cap_bytes: 1024 * 1024,
        }
    }
}

/// Point-in-time adapter state. Resume and tail pointers are opaque
/// provider bytes the core stores but never parses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterSnapshot {
    pub running: bool,
    pub exit_code: Option<u32>,
    pub provider_session_id: Option<String>,
    pub resume_pointer: Option<String>,
}

/// The contract every adapter implements. Methods are object-safe;
/// dispatch is an enum match so new providers break compilation loudly.
pub trait ProviderAdapter {
    fn name(&self) -> &'static str;
    fn provider(&self) -> Provider;
    fn capabilities(&self) -> Capabilities;
    fn spawn(&mut self, req: SpawnRequest) -> Result<(), AdapterError>;
    fn inject(&mut self, input: &[u8]) -> Result<(), AdapterError>;
    fn respond_approval(
        &mut self,
        request_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ApprovalOutcome, AdapterError>;
    fn stop(&mut self) -> Result<(), AdapterError>;
    fn drain(&mut self) -> Vec<ProviderEvent>;
    fn snapshot(&self) -> AdapterSnapshot;
}
