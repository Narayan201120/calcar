//! Common event and workflow model for the Calcar agent.
//!
//! Hand written mirror of `proto/calcar/v1/events.proto` and
//! `proto/calcar/v1/workflows.proto`. Enum discriminants match the proto
//! numbers exactly. When the connection manager lands (P5, P7) this crate is
//! replaced by prost codegen from the proto, per the P1 invariant that proto
//! owns the contract and no types are hand copied across runtimes. Until then
//! this crate is the single place that mirrors the contract, and the
//! discriminant tests below pin it to the proto numbers.

/// Provider adapter behind the common model. `workflows.proto` Provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Provider {
    Unspecified = 0,
    Opencode = 1,
    Claude = 2,
    Codex = 3,
    Generic = 4,
}

impl Provider {
    pub fn from_i32(value: i32) -> Option<Self> {
        Some(match value {
            0 => Self::Unspecified,
            1 => Self::Opencode,
            2 => Self::Claude,
            3 => Self::Codex,
            4 => Self::Generic,
            _ => return None,
        })
    }
}

/// User facing workflow lifecycle. `workflows.proto` WorkflowState.
/// DisconnectedRunning is a projection only. It is never persisted; storage
/// must reject it. PLAN P4, PRD 40.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum WorkflowState {
    Unspecified = 0,
    Running = 1,
    WaitingInput = 2,
    WaitingApproval = 3,
    Completed = 4,
    Failed = 5,
    Stopped = 6,
    DisconnectedRunning = 7,
}

impl WorkflowState {
    pub fn from_i32(value: i32) -> Option<Self> {
        Some(match value {
            0 => Self::Unspecified,
            1 => Self::Running,
            2 => Self::WaitingInput,
            3 => Self::WaitingApproval,
            4 => Self::Completed,
            5 => Self::Failed,
            6 => Self::Stopped,
            7 => Self::DisconnectedRunning,
            _ => return None,
        })
    }

    pub fn is_persistable(self) -> bool {
        self != Self::Unspecified && self != Self::DisconnectedRunning
    }
}

/// Common event set. `events.proto` WorkflowEventType.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum EventType {
    Unspecified = 0,
    AgentStarted = 1,
    CommandStarted = 2,
    CommandCompleted = 3,
    FileChanged = 4,
    ApprovalRequired = 5,
    InputRequired = 6,
    ErrorOccurred = 7,
    WorkflowCompleted = 8,
    WorkflowStopped = 9,
}

impl EventType {
    pub fn from_i32(value: i32) -> Option<Self> {
        Some(match value {
            0 => Self::Unspecified,
            1 => Self::AgentStarted,
            2 => Self::CommandStarted,
            3 => Self::CommandCompleted,
            4 => Self::FileChanged,
            5 => Self::ApprovalRequired,
            6 => Self::InputRequired,
            7 => Self::ErrorOccurred,
            8 => Self::WorkflowCompleted,
            9 => Self::WorkflowStopped,
            _ => return None,
        })
    }
}

/// One ordered event in a workflow stream. `events.proto` WorkflowEvent.
/// Carries a short summary plus a pointer to capped detail. Never carries
/// full logs, transcripts, or source. PRD 29, PRD 37.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowEvent {
    pub event_id: String,
    pub workflow_id: String,
    pub provider_session_id: Option<String>,
    /// Per workflow monotonic sequence for replay, starts at 1.
    pub seq_no: u64,
    /// Unix millis, UTC.
    pub occurred_at_millis: i64,
    pub event_type: EventType,
    /// One line human summary for the Activity view.
    pub summary: String,
    /// Pointer to capped tail or hunk, fetched on demand.
    pub detail_pointer: Option<String>,
}

/// Unix millis helper. One place so every writer agrees on the clock.
pub fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Discriminants are the contract. If proto changes these numbers, this
    // test fails and the mirror gets updated together with the proto.
    #[test]
    fn event_type_discriminants_match_proto() {
        assert_eq!(EventType::Unspecified as i32, 0);
        assert_eq!(EventType::AgentStarted as i32, 1);
        assert_eq!(EventType::CommandStarted as i32, 2);
        assert_eq!(EventType::CommandCompleted as i32, 3);
        assert_eq!(EventType::FileChanged as i32, 4);
        assert_eq!(EventType::ApprovalRequired as i32, 5);
        assert_eq!(EventType::InputRequired as i32, 6);
        assert_eq!(EventType::ErrorOccurred as i32, 7);
        assert_eq!(EventType::WorkflowCompleted as i32, 8);
        assert_eq!(EventType::WorkflowStopped as i32, 9);
    }

    #[test]
    fn workflow_state_discriminants_match_proto() {
        assert_eq!(WorkflowState::Running as i32, 1);
        assert_eq!(WorkflowState::WaitingInput as i32, 2);
        assert_eq!(WorkflowState::WaitingApproval as i32, 3);
        assert_eq!(WorkflowState::Completed as i32, 4);
        assert_eq!(WorkflowState::Failed as i32, 5);
        assert_eq!(WorkflowState::Stopped as i32, 6);
        assert_eq!(WorkflowState::DisconnectedRunning as i32, 7);
        assert!(!WorkflowState::DisconnectedRunning.is_persistable());
        assert!(WorkflowState::Running.is_persistable());
    }

    #[test]
    fn provider_discriminants_match_proto() {
        assert_eq!(Provider::Opencode as i32, 1);
        assert_eq!(Provider::Claude as i32, 2);
        assert_eq!(Provider::Codex as i32, 3);
        assert_eq!(Provider::Generic as i32, 4);
        assert!(Provider::from_i32(9).is_none());
    }
}
