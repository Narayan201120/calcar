//! Input router: per-workflow UUID dedupe for phone inputs.
//!
//! Failure modes, stated first so callers wire around them:
//! 1. Unknown workflow id rejects the input with NotFound. A rejection is
//!    not a duplicate and is not counted as one.
//! 2. Empty workflow id or empty input id is refused with InvalidState.
//! 3. A repeated UUID for the same workflow is dropped and counted. The
//!    sender must reuse a UUID only when retrying the same input, never for
//!    a new one, or the new input is silently lost.
//! 4. The same UUID under different workflow ids is independent. Dedupe keys
//!    are namespaced per workflow, so id reuse across workflows still
//!    delivers once per workflow.
//! 5. Crash between claim and confirm leaves a pending row. Redelivery with
//!    the same UUID confirms and delivers it once, then later repeats drop
//!    as duplicates. Crash between confirm and the PTY write still loses one
//!    input on redelivery, because the row already reads resolved. That gap
//!    is one call wide. The 60 second drop test covers a live agent, not a
//!    kill inside that gap.
//! 6. Two threads delivering the same UUID concurrently can both read
//!    Delivered. The input path must serialize deliveries per workflow. The
//!    store is a single writer by construction.
//! 7. Delivered and duplicate counters live in memory only and reset on
//!    restart. Dedupe truth lives in SQLite, so a restart still drops old
//!    UUIDs while the counts start over.
//! 8. Forgetting a workflow on end drops its counters, not its rows. Storage
//!    rows stay as the durable record. Input volume bounds them, so no trim
//!    pass is needed.
//! 9. Resolve payloads are stored verbatim. Keep them short ids or answers,
//!    never transcripts, terminal bytes, or source. The caller owns that.
//!    On Err the caller may safely retry with the same UUID. A retry either
//!    confirms a half-claimed row or fails again, so it never applies an
//!    input twice.
//!
//! PLAN P4 input router idempotency. Dedupe writes go through [`Storage`]
//! pending requests only. This module adds no tables and no files.

use std::collections::HashMap;

use calcar_storage::{RequestKind, Storage, StorageError};

/// Outcome of one input delivery attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteOutcome {
    /// First time this UUID was seen for this workflow. The caller now owns
    /// writing the payload to the PTY exactly once.
    Delivered,
    /// This UUID already resolved for this workflow. The caller must not
    /// write anything. The input was dropped.
    Duplicate,
}

/// Routes phone inputs toward PTY stdin with first delivery wins per UUID.
/// The durable dedupe key is one pending request row per (workflow, UUID).
/// Counters are process stats only.
pub struct InputRouter<'a> {
    storage: &'a Storage,
    delivered: HashMap<String, u64>,
    duplicates: HashMap<String, u64>,
}

impl<'a> InputRouter<'a> {
    /// Borrow the store. Shares one connection with the other managers.
    pub fn new(storage: &'a Storage) -> Self {
        Self {
            storage,
            delivered: HashMap::new(),
            duplicates: HashMap::new(),
        }
    }

    /// Deliver one input. The first UUID per workflow wins and resolves its
    /// row with `payload`. Repeats drop as duplicates and bump the counter.
    /// A repeat that finds its row still pending (claim without confirm, the
    /// agent died in between) confirms and delivers it once.
    /// Fails on empty ids (InvalidState), unknown workflow (NotFound),
    /// storage IO.
    pub fn deliver(
        &mut self,
        workflow_id: &str,
        input_id: &str,
        payload: &str,
    ) -> Result<RouteOutcome, StorageError> {
        if workflow_id.is_empty() {
            return Err(StorageError::InvalidState(
                "workflow id must not be empty".to_string(),
            ));
        }
        if input_id.is_empty() {
            return Err(StorageError::InvalidState(
                "input id must not be empty".to_string(),
            ));
        }
        let key = storage_key(workflow_id, input_id);
        match self
            .storage
            .create_pending_request(&key, workflow_id, RequestKind::Input, None)
        {
            Ok(()) => {
                self.storage.resolve_pending_request(&key, payload)?;
                bump(&mut self.delivered, workflow_id);
                Ok(RouteOutcome::Delivered)
            }
            Err(first) => match self.storage.resolve_pending_request(&key, payload) {
                // Row existed but was never confirmed. The earlier attempt
                // died between claim and confirm, so this retry applies it.
                Ok(()) => {
                    bump(&mut self.delivered, workflow_id);
                    Ok(RouteOutcome::Delivered)
                }
                // Row already resolved or expired. A true repeat, drop it.
                Err(StorageError::AlreadyResolved(_)) | Err(StorageError::Expired(_)) => {
                    bump(&mut self.duplicates, workflow_id);
                    Ok(RouteOutcome::Duplicate)
                }
                // No row at all. The create failed for its own reason
                // (unknown workflow, IO). Report that, not the resolve.
                Err(_) => Err(first),
            },
        }
    }

    /// Inputs delivered for one workflow in this process lifetime.
    pub fn delivered_for(&self, workflow_id: &str) -> u64 {
        self.delivered.get(workflow_id).copied().unwrap_or(0)
    }

    /// Duplicate UUIDs dropped for one workflow in this process lifetime.
    pub fn duplicates_for(&self, workflow_id: &str) -> u64 {
        self.duplicates.get(workflow_id).copied().unwrap_or(0)
    }

    /// Totals across workflows in this process lifetime, delivered first.
    pub fn totals(&self) -> (u64, u64) {
        (
            self.delivered.values().sum(),
            self.duplicates.values().sum(),
        )
    }

    /// Drop a finished workflow's counters. Call when the workflow reaches a
    /// terminal state so keys expire with the workflow end. Storage rows are
    /// left alone as the durable record. Returns the evicted counts,
    /// delivered first.
    pub fn forget_workflow(&mut self, workflow_id: &str) -> (u64, u64) {
        (
            self.delivered.remove(workflow_id).unwrap_or(0),
            self.duplicates.remove(workflow_id).unwrap_or(0),
        )
    }
}

/// Storage request id for one input. Namespaced so the same phone UUID under
/// two workflows stays two independent deliveries.
fn storage_key(workflow_id: &str, input_id: &str) -> String {
    format!("input:{workflow_id}:{input_id}")
}

fn bump(counts: &mut HashMap<String, u64>, workflow_id: &str) {
    *counts.entry(workflow_id.to_string()).or_insert(0) += 1;
}
