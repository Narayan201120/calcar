//! Sole writer of workflow state. PLAN P4, DEC-014, DEC-028.
//!
//! Every state change funnels through [`WorkflowManager`] into [`Storage`].
//! Stored invariants, checked here and re-checked at the SQL layer:
//! unspecified is refused, disconnected-running is a read-time projection
//! never stored, terminal states are frozen, completed-on-disconnect refused.

use calcar_events::{now_millis, EventType, Provider, WorkflowEvent, WorkflowState};
use calcar_storage::{EventDraft, Storage, StorageError, WorkflowRow};
use thiserror::Error;

/// How lifecycle operations fail. Storage faults pass through untouched so
/// callers can still match on [`StorageError`]; policy refusals are `Refused`.
#[derive(Debug, Error)]
pub enum LifecycleError {
    /// Policy refusal: bad input, projection write, disconnect completed.
    #[error("transition refused: {0}")]
    Refused(String),
    /// SQLite, IO, migration, not-found, terminal-frozen faults.
    #[error(transparent)]
    Storage(#[from] StorageError),
}

/// Stored row plus its connection projection. Terminal rows project to
/// themselves; anything else projects to disconnected-running while the
/// phone is away. Building this never writes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowView {
    pub stored: WorkflowRow,
    pub projected: WorkflowState,
}

/// Restart recovery outcome. The seam for the P4 recovery test: kill the
/// agent mid-run, reboot, call [`WorkflowManager::reconcile`], assert
/// reattach or clean-failed with reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryDecision {
    /// Stored binding plus replayed events; the caller reattaches to the
    /// same provider session and resumes from `last_seq`.
    Reattach {
        provider_session_id: String,
        resume_pointer: Option<String>,
        replayed_events: usize,
        last_seq: Option<u64>,
    },
    /// No binding survived, so the workflow was marked failed with reason.
    /// Stored state changed; the reason is also in the event ring.
    CleanFailed { reason: String },
    /// Already completed, failed, or stopped: nothing to recover.
    AlreadyTerminal { state: WorkflowState },
}

/// The sole writer of workflow state. Holds the [`Storage`], which stays the
/// only module touching SQLite. All methods take `&self`; the store is the
/// single writer by construction.
pub struct WorkflowManager {
    storage: Storage,
}

impl WorkflowManager {
    /// Wrap an opened store and run pending migrations. Fails on IO or a
    /// broken migration.
    pub fn new(mut storage: Storage) -> Result<Self, LifecycleError> {
        storage.migrate()?;
        Ok(Self { storage })
    }

    /// Open the agent database at `path`, migrating on first run.
    /// Fails on IO, a broken migration.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self, LifecycleError> {
        Self::new(Storage::open(path)?)
    }

    /// In-memory manager for harnesses and E2E setup. Fails on migration.
    pub fn in_memory() -> Result<Self, LifecycleError> {
        Self::new(Storage::open_in_memory()?)
    }

    /// Start a workflow in running state. Binds the provider session when
    /// given so restart recovery can reattach.
    /// Fails: empty id, empty title, unspecified provider, duplicate id,
    /// storage IO.
    pub fn create_workflow(
        &self,
        workflow_id: &str,
        provider: Provider,
        title: &str,
        provider_session_id: Option<&str>,
    ) -> Result<WorkflowRow, LifecycleError> {
        if workflow_id.is_empty() {
            return Err(LifecycleError::Refused(
                "workflow id must not be empty".to_string(),
            ));
        }
        if title.is_empty() {
            return Err(LifecycleError::Refused(
                "workflow title must not be empty".to_string(),
            ));
        }
        if provider == Provider::Unspecified {
            return Err(LifecycleError::Refused(
                "provider must be specified".to_string(),
            ));
        }
        let row =
            self.storage
                .create_workflow(workflow_id, provider, title, provider_session_id)?;
        if let Some(session_id) = provider_session_id {
            self.storage
                .upsert_session_binding(workflow_id, session_id, None)?;
        }
        self.record(
            &row.workflow_id,
            row.provider_session_id.as_deref(),
            WorkflowState::Running,
            "workflow created",
        )?;
        Ok(row)
    }

    /// Move a workflow to `next` with a human-readable `reason`. The reason
    /// is appended to the event ring, so every state change carries its why.
    /// Fails: empty reason, unknown id (NotFound), unspecified or
    /// disconnected-running target (Refused, never stored), move out of a
    /// terminal state (InvalidState, frozen), event append IO.
    pub fn transition(
        &self,
        workflow_id: &str,
        next: WorkflowState,
        reason: &str,
    ) -> Result<WorkflowRow, LifecycleError> {
        check_storable(next)?;
        check_reason(reason)?;
        let row = self.storage.set_workflow_state(workflow_id, next)?;
        self.record(
            &row.workflow_id,
            row.provider_session_id.as_deref(),
            next,
            reason,
        )?;
        Ok(row)
    }

    /// Transition on a disconnect path. Identical to [`transition`] except a
    /// move to completed is refused: phone disconnect never ends a workflow
    /// (PLAN P4 invariant). Stored state is unchanged on refusal.
    /// Fails: everything [`transition`] fails on, plus completed target.
    pub fn transition_on_disconnect(
        &self,
        workflow_id: &str,
        next: WorkflowState,
        reason: &str,
    ) -> Result<WorkflowRow, LifecycleError> {
        if next == WorkflowState::Completed {
            return Err(LifecycleError::Refused(
                "disconnect never completes a workflow; stored state is unchanged".to_string(),
            ));
        }
        self.transition(workflow_id, next, reason)
    }

    /// Read the stored row. Fails on storage IO. Unknown id yields None.
    pub fn get_workflow(&self, workflow_id: &str) -> Result<Option<WorkflowRow>, LifecycleError> {
        Ok(self.storage.get_workflow(workflow_id)?)
    }

    /// Replay events strictly after `after_seq`, in seq order. Unknown id
    /// yields an empty vec. Fails on storage IO.
    pub fn events_since(
        &self,
        workflow_id: &str,
        after_seq: i64,
        limit: u32,
    ) -> Result<Vec<WorkflowEvent>, LifecycleError> {
        Ok(self.storage.events_after(workflow_id, after_seq, limit)?)
    }

    /// Connection projection for a disconnected phone. Reads only, never
    /// writes: non-terminal stored states project to disconnected-running,
    /// terminal states project to themselves.
    /// Fails: unknown id (NotFound), corrupt stored state, storage IO.
    pub fn project_on_disconnect(&self, workflow_id: &str) -> Result<WorkflowView, LifecycleError> {
        let stored = self
            .storage
            .get_workflow(workflow_id)?
            .ok_or_else(|| StorageError::NotFound(format!("workflow {workflow_id}")))?;
        let stored_state = WorkflowState::from_i32(stored.state).ok_or_else(|| {
            LifecycleError::Refused(format!(
                "stored state {} for workflow {workflow_id} is not a known state",
                stored.state
            ))
        })?;
        let projected = match stored_state {
            WorkflowState::Completed | WorkflowState::Failed | WorkflowState::Stopped => {
                stored_state
            }
            WorkflowState::Unspecified | WorkflowState::DisconnectedRunning => {
                return Err(LifecycleError::Refused(format!(
                    "stored state {stored_state:?} for workflow {workflow_id} must never persist"
                )));
            }
            WorkflowState::Running
            | WorkflowState::WaitingInput
            | WorkflowState::WaitingApproval => WorkflowState::DisconnectedRunning,
        };
        Ok(WorkflowView { stored, projected })
    }

    /// Restart recovery seam. Replays stored events and the session binding:
    /// binding present means reattach to the same provider session, binding
    /// absent means mark failed with reason (clean-failed). Terminal rows
    /// need no recovery.
    /// Fails: unknown id (NotFound), corrupt stored state, storage IO.
    pub fn reconcile(&self, workflow_id: &str) -> Result<RecoveryDecision, LifecycleError> {
        let stored = self
            .storage
            .get_workflow(workflow_id)?
            .ok_or_else(|| StorageError::NotFound(format!("workflow {workflow_id}")))?;
        let state = WorkflowState::from_i32(stored.state).ok_or_else(|| {
            LifecycleError::Refused(format!(
                "stored state {} for workflow {workflow_id} is not a known state",
                stored.state
            ))
        })?;
        match state {
            WorkflowState::Completed | WorkflowState::Failed | WorkflowState::Stopped => {
                Ok(RecoveryDecision::AlreadyTerminal { state })
            }
            WorkflowState::Unspecified | WorkflowState::DisconnectedRunning => {
                Err(LifecycleError::Refused(format!(
                    "stored state {state:?} for workflow {workflow_id} must never persist"
                )))
            }
            WorkflowState::Running
            | WorkflowState::WaitingInput
            | WorkflowState::WaitingApproval => {
                let binding = self.storage.get_session_binding(workflow_id)?;
                let replayed = self.storage.events_after(workflow_id, 0, u32::MAX)?;
                match binding {
                    Some((provider_session_id, resume_pointer)) => Ok(RecoveryDecision::Reattach {
                        provider_session_id,
                        resume_pointer,
                        last_seq: replayed.last().map(|event| event.seq_no),
                        replayed_events: replayed.len(),
                    }),
                    None => {
                        let reason = format!(
                            "restart recovery: no session binding for workflow {workflow_id}; marked failed"
                        );
                        self.storage
                            .set_workflow_state(workflow_id, WorkflowState::Failed)?;
                        self.record(
                            workflow_id,
                            stored.provider_session_id.as_deref(),
                            WorkflowState::Failed,
                            &reason,
                        )?;
                        Ok(RecoveryDecision::CleanFailed { reason })
                    }
                }
            }
        }
    }

    /// Append the lifecycle event behind a state change. The event ring is
    /// annotation; state is truth, so callers persist state first.
    fn record(
        &self,
        workflow_id: &str,
        provider_session_id: Option<&str>,
        next: WorkflowState,
        reason: &str,
    ) -> Result<WorkflowEvent, LifecycleError> {
        let event_type = match next {
            WorkflowState::Running => EventType::AgentStarted,
            WorkflowState::WaitingInput => EventType::InputRequired,
            WorkflowState::WaitingApproval => EventType::ApprovalRequired,
            WorkflowState::Completed => EventType::WorkflowCompleted,
            WorkflowState::Failed => EventType::ErrorOccurred,
            WorkflowState::Stopped => EventType::WorkflowStopped,
            WorkflowState::Unspecified | WorkflowState::DisconnectedRunning => {
                return Err(LifecycleError::Refused(format!(
                    "state {next:?} is never stored and gets no lifecycle event"
                )));
            }
        };
        let occurred = now_millis();
        Ok(self.storage.append_event(EventDraft {
            workflow_id: workflow_id.to_string(),
            event_id: format!("lifecycle-{workflow_id}-{}-{occurred}", next as i32),
            provider_session_id: provider_session_id.map(str::to_string),
            occurred_at_millis: occurred,
            event_type,
            summary: reason.to_string(),
            detail_pointer: None,
        })?)
    }
}

/// Reject targets that must never reach the table. Storage re-checks this
/// at the SQL layer; the manager refuses early with a clearer error.
fn check_storable(next: WorkflowState) -> Result<(), LifecycleError> {
    match next {
        WorkflowState::Unspecified => Err(LifecycleError::Refused(
            "unspecified state is never persisted".to_string(),
        )),
        WorkflowState::DisconnectedRunning => Err(LifecycleError::Refused(
            "disconnected-running is a projection only; use project_on_disconnect".to_string(),
        )),
        WorkflowState::Running
        | WorkflowState::WaitingInput
        | WorkflowState::WaitingApproval
        | WorkflowState::Completed
        | WorkflowState::Failed
        | WorkflowState::Stopped => Ok(()),
    }
}

/// A transition without a reason is a transition nobody can audit. Refuse it.
fn check_reason(reason: &str) -> Result<&str, LifecycleError> {
    if reason.is_empty() {
        return Err(LifecycleError::Refused(
            "transition reason must not be empty".to_string(),
        ));
    }
    Ok(reason)
}
