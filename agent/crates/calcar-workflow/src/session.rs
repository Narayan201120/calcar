//! Session bindings: workflow id to provider session id.
//!
//! Failure modes, stated first so callers wire around them:
//! 1. Bind for an unknown workflow id fails with NotFound. Lifecycle creates
//!    the workflow row first. This module never creates one.
//! 2. Empty workflow id or empty provider session id is refused. An empty
//!    binding could never reattach, so fail fast instead of storing it.
//! 3. Bind is last writer wins. Two agent processes sharing one database file
//!    would overwrite each other, so exactly one agent may open it.
//! 4. A workflow row with no binding is normal after a crash between create
//!    and bind. Lookup returns None there, and recovery takes the
//!    clean-failed path, never a reattach.
//! 5. A stored binding can be stale. The provider may have dropped the native
//!    session on its side. Lookup succeeding does not prove the session is
//!    still resumable. The adapter reattach call proves that. On failure the
//!    caller spawns fresh and binds the new id.
//! 6. The resume pointer is an opaque provider hint. This module stores and
//!    returns it byte for byte and never interprets it.
//! 7. Storage faults pass through as StorageError. There is no in-memory
//!    fallback copy. A fallback would fork the truth.
//!
//! PLAN P4 restart recovery. Reads and writes go through [`Storage`] only.
//! This module keeps no maps, no files, no caches of its own.

use calcar_storage::{Storage, StorageError};

/// One stored binding: the provider native session a workflow resumes on,
/// plus the opaque pointer the provider needs to resume there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionBinding {
    pub workflow_id: String,
    pub provider_session_id: String,
    pub resume_pointer: Option<String>,
}

/// Binds workflow ids to provider sessions and answers reattach lookups.
/// Thin wrapper over [`Storage`]. Every method is one storage call plus
/// argument checks.
pub struct SessionManager<'a> {
    storage: &'a Storage,
}

impl<'a> SessionManager<'a> {
    /// Borrow the store. The caller keeps ownership, so one connection can
    /// serve the lifecycle manager, this manager, and the input router.
    pub fn new(storage: &'a Storage) -> Self {
        Self { storage }
    }

    /// Record or replace the provider session for `workflow_id`.
    /// Fails on empty ids (InvalidState), unknown workflow (NotFound),
    /// storage IO.
    pub fn bind(
        &self,
        workflow_id: &str,
        provider_session_id: &str,
        resume_pointer: Option<&str>,
    ) -> Result<(), StorageError> {
        if workflow_id.is_empty() {
            return Err(StorageError::InvalidState(
                "workflow id must not be empty".to_string(),
            ));
        }
        if provider_session_id.is_empty() {
            return Err(StorageError::InvalidState(
                "provider session id must not be empty".to_string(),
            ));
        }
        if self.storage.get_workflow(workflow_id)?.is_none() {
            return Err(StorageError::NotFound(format!("workflow {workflow_id}")));
        }
        self.storage
            .upsert_session_binding(workflow_id, provider_session_id, resume_pointer)
    }

    /// Fetch the binding for `workflow_id`. This is the reattach read for
    /// restart recovery: Some means resume that provider session, None means
    /// take the clean-failed path instead. Unknown workflow also yields None.
    /// Binding absence and workflow absence both mean there is nothing to
    /// reattach to. Fails on storage IO only.
    pub fn lookup(&self, workflow_id: &str) -> Result<Option<SessionBinding>, StorageError> {
        match self.storage.get_session_binding(workflow_id)? {
            None => Ok(None),
            Some((provider_session_id, resume_pointer)) => Ok(Some(SessionBinding {
                workflow_id: workflow_id.to_string(),
                provider_session_id,
                resume_pointer,
            })),
        }
    }
}
