//! Approval permission manager, P5.
//!
//! Failure modes first. Read these before calling anything.
//!
//! - Unknown id resolves to `Unknown`, never an error. That covers ids that
//!   never existed, ids from a previous process lifetime (bindings are
//!   memory-only, see below), and bare ids that match requests in more than
//!   one workflow. Fail-closed on purpose.
//! - Wrong device resolves to `Unknown` and never touches storage. No verdict
//!   is recorded, so the bound device can still resolve afterwards.
//! - Repeat resolve by the bound device returns `Duplicate`. The first verdict
//!   stands. Storage enforces the same single-resolve rule underneath.
//! - Past TTL resolves to `Expired`. Expiry is checked lazily inside storage
//!   on every resolve, and `sweep_expired` flips overdue rows in bulk. There
//!   are no background threads; nothing expires unless you call one of those.
//! - Double `request` for the same workflow plus request id fails with the
//!   storage primary-key error. Requests are single-use, so re-asking needs a
//!   fresh request id.
//! - `request` for a workflow storage does not know fails with `NotFound`.
//!   Empty workflow, request, or device ids fail with `InvalidState`.
//! - Restart drops every device binding. The storage rows survive, but this
//!   manager will answer `Unknown` for pre-restart requests because it can no
//!   longer prove which device owns them. Re-requesting the same id after a
//!   restart collides loudly instead of silently rebinding.
//!
//! Keys are namespaced per workflow plus request (`workflow:request`) so the
//! same bare request id can exist in two workflows without sharing fate. The
//! summary is card text for the owner device; it is folded into the resolve
//! payload as `allow:<summary>` or `reject:<summary>` because the storage
//! schema intentionally has no summary column. Durable lifecycle state lives
//! in storage. Device bindings and the pending index live in memory.

use std::collections::HashMap;
use std::sync::Mutex;

use calcar_storage::{RequestKind, Storage, StorageError};

use crate::traitdef::{ApprovalDecision, ApprovalOutcome};

/// One tracked approval: routing plus the device it is bound to.
struct PendingEntry {
    workflow_id: String,
    request_id: String,
    device_id: String,
    summary: String,
    expires_at_millis: i64,
    resolved: bool,
}

/// Owns the approval lifecycle for P5. Borrows storage, keeps bindings in
/// memory, spawns nothing. One instance per process; the storage row is the
/// durable truth, the map beside it is the device check.
pub struct PermissionManager<'a> {
    storage: &'a Storage,
    pending: Mutex<HashMap<String, PendingEntry>>,
}

fn namespaced_key(workflow_id: &str, request_id: &str) -> String {
    format!("{workflow_id}:{request_id}")
}

fn decision_word(decision: ApprovalDecision) -> &'static str {
    match decision {
        ApprovalDecision::Allow => "allow",
        ApprovalDecision::Reject => "reject",
    }
}

impl<'a> PermissionManager<'a> {
    /// Borrow storage. No rows are touched until `request` is called.
    pub fn new(storage: &'a Storage) -> Self {
        Self {
            storage,
            pending: Mutex::new(HashMap::new()),
        }
    }

    /// Record one approval bound to one device, expiring `ttl` after now.
    /// Unknown workflows and repeat ids report through storage errors.
    pub fn request(
        &self,
        workflow_id: &str,
        request_id: &str,
        device_id: &str,
        summary: &str,
        ttl: std::time::Duration,
    ) -> Result<(), StorageError> {
        if workflow_id.is_empty() || request_id.is_empty() || device_id.is_empty() {
            return Err(StorageError::InvalidState(
                "workflow_id, request_id, and device_id must be non-empty".to_string(),
            ));
        }
        let ttl_millis = ttl.as_millis().min(i64::MAX as u128) as i64;
        let expires_at_millis = calcar_events::now_millis().saturating_add(ttl_millis);
        let key = namespaced_key(workflow_id, request_id);
        self.storage.create_pending_request(
            &key,
            workflow_id,
            RequestKind::Approval,
            Some(expires_at_millis),
        )?;
        self.pending
            .lock()
            .map_err(|_| StorageError::InvalidState("permission map poisoned".to_string()))?
            .insert(
                key,
                PendingEntry {
                    workflow_id: workflow_id.to_string(),
                    request_id: request_id.to_string(),
                    device_id: device_id.to_string(),
                    summary: summary.to_string(),
                    expires_at_millis,
                    resolved: false,
                },
            );
        Ok(())
    }

    /// Apply a verdict. Accepts the namespaced key or, when it matches exactly
    /// one tracked request, the bare request id. Anything else is `Unknown`.
    pub fn resolve(
        &self,
        request_id: &str,
        device_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ApprovalOutcome, StorageError> {
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| StorageError::InvalidState("permission map poisoned".to_string()))?;
        let key = if pending.contains_key(request_id) {
            Some(request_id.to_string())
        } else {
            let mut hits: Vec<String> = pending
                .iter()
                .filter(|(_, entry)| entry.request_id == request_id)
                .map(|(key, _)| key.clone())
                .collect();
            if hits.len() == 1 {
                hits.pop()
            } else {
                None
            }
        };
        let Some(key) = key else {
            return Ok(ApprovalOutcome::Unknown);
        };
        let payload = {
            let entry = pending.get(&key).ok_or_else(|| {
                StorageError::InvalidState("permission map changed mid-resolve".to_string())
            })?;
            if entry.device_id != device_id {
                return Ok(ApprovalOutcome::Unknown);
            }
            if entry.resolved {
                return Ok(ApprovalOutcome::Duplicate);
            }
            format!("{}:{}", decision_word(decision), entry.summary)
        };
        match self.storage.resolve_pending_request(&key, &payload) {
            Ok(()) => {
                if let Some(entry) = pending.get_mut(&key) {
                    entry.resolved = true;
                }
                Ok(ApprovalOutcome::Applied)
            }
            Err(StorageError::AlreadyResolved(_)) => {
                if let Some(entry) = pending.get_mut(&key) {
                    entry.resolved = true;
                }
                Ok(ApprovalOutcome::Duplicate)
            }
            Err(StorageError::Expired(_)) => Ok(ApprovalOutcome::Expired),
            Err(StorageError::NotFound(_)) => Ok(ApprovalOutcome::Unknown),
            Err(other) => Err(other),
        }
    }

    /// Flip every overdue pending row to expired. Returns how many flipped.
    /// Call this on a timer in core; the manager itself never wakes up alone.
    pub fn sweep_expired(&self) -> Result<usize, StorageError> {
        let flipped = self.storage.expire_pending_requests()?;
        Ok(flipped.max(0) as usize)
    }

    /// Bare request ids still awaiting a verdict in one workflow, sorted.
    /// Settled and overdue ids are left out.
    pub fn pending_for(&self, workflow_id: &str) -> Result<Vec<String>, StorageError> {
        let pending = self
            .pending
            .lock()
            .map_err(|_| StorageError::InvalidState("permission map poisoned".to_string()))?;
        let now = calcar_events::now_millis();
        let mut out: Vec<String> = pending
            .values()
            .filter(|entry| {
                entry.workflow_id == workflow_id && !entry.resolved && entry.expires_at_millis > now
            })
            .map(|entry| entry.request_id.clone())
            .collect();
        out.sort();
        Ok(out)
    }
}
