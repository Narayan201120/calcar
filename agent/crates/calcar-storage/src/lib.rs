//! Calcar agent storage. PLAN P4: the only module that touches SQLite.
//!
//! One file per computer, WAL mode, single writer. This skeleton gives the
//! slice 1 baseline: open with the right pragmas, embedded ordered migrations,
//! idempotent migrate. The event ring, trim, replay, and outbox cursors build
//! on this in the same crate.

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("migration {name} failed: {message}")]
    Migration { name: String, message: String },
    #[error("invalid state: {0}")]
    InvalidState(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("request already resolved: {0}")]
    AlreadyResolved(String),
    #[error("request expired: {0}")]
    Expired(String),
}

/// Applied migration record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedMigration {
    pub name: String,
    pub applied_at_millis: i64,
}

pub struct Storage {
    conn: Connection,
    path: Option<PathBuf>,
}

/// (name, sql) in apply order. New migrations append here, never edit history.
const MIGRATIONS: &[(&str, &str)] = &[("0001_init", include_str!("../migrations/0001_init.sql"))];

impl Storage {
    /// Open (creating if needed) and configure the database. WAL keeps readers
    /// cheap while this process stays the single writer.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let conn = Connection::open(&path)?;
        Self::configure(&conn)?;
        Ok(Self {
            conn,
            path: Some(path),
        })
    }

    /// In memory store for tests and the doctor migrate check.
    pub fn open_in_memory() -> Result<Self, StorageError> {
        let conn = Connection::open_in_memory()?;
        Self::configure(&conn)?;
        Ok(Self { conn, path: None })
    }

    fn configure(conn: &Connection) -> Result<(), StorageError> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "busy_timeout", 5_000)?;
        Ok(())
    }

    /// Apply pending migrations in order. Re-running is a no-op.
    pub fn migrate(&mut self) -> Result<Vec<String>, StorageError> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                 id INTEGER PRIMARY KEY,
                 name TEXT NOT NULL UNIQUE,
                 applied_at_millis INTEGER NOT NULL
             )",
        )?;
        let already_applied: Vec<String> = self
            .conn
            .prepare("SELECT name FROM schema_migrations ORDER BY id")?
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        let mut newly_applied = Vec::new();
        for (name, sql) in MIGRATIONS {
            if already_applied.iter().any(|a| a == name) {
                continue;
            }
            let tx = self.conn.transaction()?;
            if let Err(error) = tx.execute_batch(sql) {
                return Err(StorageError::Migration {
                    name: (*name).to_string(),
                    message: error.to_string(),
                });
            }
            tx.execute(
                "INSERT INTO schema_migrations (name, applied_at_millis) VALUES (?1, ?2)",
                rusqlite::params![name, calcar_events::now_millis()],
            )?;
            tx.commit()?;
            newly_applied.push((*name).to_string());
        }
        Ok(newly_applied)
    }

    /// Where the database lives, or None for the in memory store.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Test helper: the live connection for in crate tests.
    #[cfg(test)]
    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }
}

// --- workflow records ---------------------------------------------------------

/// Bounded ring limits per workflow. PLAN P4: about 5k events or 10 MB.
pub const MAX_RING_EVENTS: i64 = 5_000;
pub const MAX_RING_BYTES: i64 = 10 * 1024 * 1024;

/// A stored workflow row. Mirrors the workflows table and
/// `workflows.proto` Workflow. `provider` and `state` are proto discriminants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowRow {
    pub workflow_id: String,
    pub provider: i32,
    pub state: i32,
    pub title: String,
    pub provider_session_id: Option<String>,
    pub created_at_millis: i64,
    pub updated_at_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RingStats {
    pub count: i64,
    pub approx_bytes: i64,
    pub oldest_seq: Option<i64>,
    pub newest_seq: Option<i64>,
    /// Everything before this seq was trimmed. Replay starts here or later.
    pub truncated_before_seq: Option<i64>,
    pub dropped_count: i64,
}

/// Input plus approval request kinds. Matches pending_requests.kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum RequestKind {
    Input = 1,
    Approval = 2,
}

impl RequestKind {
    pub fn from_i32(value: i32) -> Option<Self> {
        Some(match value {
            1 => Self::Input,
            2 => Self::Approval,
            _ => return None,
        })
    }
}

/// Pending request lifecycle. Single resolve wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum RequestState {
    Pending = 1,
    Resolved = 2,
    Expired = 3,
}

impl StorageError {
    fn invalid_state(message: impl Into<String>) -> Self {
        StorageError::InvalidState(message.into())
    }
}

/// Draft for a new event. The store assigns seq_no; callers never set it.
#[derive(Debug, Clone)]
pub struct EventDraft {
    pub workflow_id: String,
    pub event_id: String,
    pub provider_session_id: Option<String>,
    pub occurred_at_millis: i64,
    pub event_type: calcar_events::EventType,
    pub summary: String,
    pub detail_pointer: Option<String>,
}

const TERMINAL_STATES: &[i32] = &[4, 5, 6]; // completed, failed, stopped

fn approx_bytes(
    summary: &str,
    detail_pointer: Option<&str>,
    event_id: &str,
    provider_session_id: Option<&str>,
) -> i64 {
    // Fixed row overhead plus string lengths. Approximate on purpose; the
    // bound is a memory guard, not an accounting exercise.
    64 + summary.len() as i64
        + detail_pointer.map(|s| s.len()).unwrap_or(0) as i64
        + event_id.len() as i64
        + provider_session_id.map(|s| s.len()).unwrap_or(0) as i64
}

// --- workflow CRUD and state machine ------------------------------------------

impl Storage {
    pub fn create_workflow(
        &self,
        workflow_id: &str,
        provider: calcar_events::Provider,
        title: &str,
        provider_session_id: Option<&str>,
    ) -> Result<WorkflowRow, StorageError> {
        let now = calcar_events::now_millis();
        self.conn.execute(
            "INSERT INTO workflows (workflow_id, provider, state, title, provider_session_id, created_at_millis, updated_at_millis)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
            rusqlite::params![
                workflow_id,
                provider as i32,
                calcar_events::WorkflowState::Running as i32,
                title,
                provider_session_id,
                now
            ],
        )?;
        Ok(WorkflowRow {
            workflow_id: workflow_id.to_string(),
            provider: provider as i32,
            state: calcar_events::WorkflowState::Running as i32,
            title: title.to_string(),
            provider_session_id: provider_session_id.map(|s| s.to_string()),
            created_at_millis: now,
            updated_at_millis: now,
        })
    }

    pub fn get_workflow(&self, workflow_id: &str) -> Result<Option<WorkflowRow>, StorageError> {
        let mut stmt = self.conn.prepare(
            "SELECT workflow_id, provider, state, title, provider_session_id, created_at_millis, updated_at_millis
             FROM workflows WHERE workflow_id = ?1",
        )?;
        let mut rows = stmt.query([workflow_id])?;
        match rows.next()? {
            None => Ok(None),
            Some(row) => Ok(Some(WorkflowRow {
                workflow_id: row.get(0)?,
                provider: row.get(1)?,
                state: row.get(2)?,
                title: row.get(3)?,
                provider_session_id: row.get(4)?,
                created_at_millis: row.get(5)?,
                updated_at_millis: row.get(6)?,
            })),
        }
    }

    /// Persisted state transition. The disconnected projection and the
    /// unspecified value never reach this table, and terminal states are
    /// final: a workflow that completed, failed, or stopped stays there.
    pub fn set_workflow_state(
        &self,
        workflow_id: &str,
        new_state: calcar_events::WorkflowState,
    ) -> Result<WorkflowRow, StorageError> {
        if !new_state.is_persistable() {
            return Err(StorageError::invalid_state(format!(
                "state {new_state:?} is a projection or unspecified and is never persisted"
            )));
        }
        let current = self
            .get_workflow(workflow_id)?
            .ok_or_else(|| StorageError::NotFound(format!("workflow {workflow_id}")))?;
        if TERMINAL_STATES.contains(&current.state) {
            return Err(StorageError::invalid_state(format!(
                "workflow {workflow_id} is in terminal state {}; no transitions out",
                current.state
            )));
        }
        self.conn.execute(
            "UPDATE workflows SET state = ?2, updated_at_millis = ?3 WHERE workflow_id = ?1",
            rusqlite::params![workflow_id, new_state as i32, calcar_events::now_millis()],
        )?;
        self.get_workflow(workflow_id)?
            .ok_or_else(|| StorageError::NotFound(format!("workflow {workflow_id}")))
    }
}

// --- event ring: append, trim, replay -----------------------------------------

impl Storage {
    /// Append one event and enqueue it on the outbox in the same transaction,
    /// then trim the ring inside the same transaction. A crash can never leave
    /// an event without its outbox row or an unbounded ring.
    pub fn append_event(
        &self,
        draft: EventDraft,
    ) -> Result<calcar_events::WorkflowEvent, StorageError> {
        if self.get_workflow(&draft.workflow_id)?.is_none() {
            return Err(StorageError::NotFound(format!(
                "workflow {}",
                draft.workflow_id
            )));
        }
        let bytes = approx_bytes(
            &draft.summary,
            draft.detail_pointer.as_deref(),
            &draft.event_id,
            draft.provider_session_id.as_deref(),
        );
        let tx = self.conn.unchecked_transaction()?;
        let seq: i64 = tx
            .query_row(
                "SELECT COALESCE(MAX(seq_no), 0) + 1 FROM workflow_events WHERE workflow_id = ?1",
                [&draft.workflow_id],
                |row| row.get(0),
            )
            .map_err(StorageError::from)?;
        tx.execute(
            "INSERT INTO workflow_events
               (workflow_id, seq_no, event_id, provider_session_id, type, occurred_at_millis, summary, detail_pointer, approx_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                draft.workflow_id,
                seq,
                draft.event_id,
                draft.provider_session_id,
                draft.event_type as i32,
                draft.occurred_at_millis,
                draft.summary,
                draft.detail_pointer,
                bytes
            ],
        )?;
        tx.execute(
            "INSERT INTO outbox (workflow_id, seq_no, enqueued_at_millis) VALUES (?1, ?2, ?3)",
            rusqlite::params![draft.workflow_id, seq, calcar_events::now_millis()],
        )?;
        trim_ring(&tx, &draft.workflow_id)?;
        tx.commit()?;
        Ok(calcar_events::WorkflowEvent {
            event_id: draft.event_id,
            workflow_id: draft.workflow_id,
            provider_session_id: draft.provider_session_id,
            seq_no: seq as u64,
            occurred_at_millis: draft.occurred_at_millis,
            event_type: draft.event_type,
            summary: draft.summary,
            detail_pointer: draft.detail_pointer,
        })
    }

    /// Replay: events strictly after `after_seq`, in seq order. Callers recovering
    /// after a disconnect read with the last seq they saw.
    pub fn events_after(
        &self,
        workflow_id: &str,
        after_seq: i64,
        limit: u32,
    ) -> Result<Vec<calcar_events::WorkflowEvent>, StorageError> {
        let mut stmt = self.conn.prepare(
            "SELECT event_id, provider_session_id, seq_no, occurred_at_millis, type, summary, detail_pointer, workflow_id
             FROM workflow_events WHERE workflow_id = ?1 AND seq_no > ?2
             ORDER BY seq_no ASC LIMIT ?3",
        )?;
        let rows = stmt.query_map(rusqlite::params![workflow_id, after_seq, limit], map_event)?;
        rows.collect::<Result<Vec<_>, rusqlite::Error>>()
            .map_err(StorageError::from)
    }

    pub fn ring_stats(&self, workflow_id: &str) -> Result<RingStats, StorageError> {
        let (count, bytes): (i64, i64) = self.conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(approx_bytes), 0) FROM workflow_events WHERE workflow_id = ?1",
            [workflow_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let (oldest, newest): (Option<i64>, Option<i64>) = self.conn.query_row(
            "SELECT MIN(seq_no), MAX(seq_no) FROM workflow_events WHERE workflow_id = ?1",
            [workflow_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let (truncated_before_seq, dropped_count) = match self
            .conn
            .query_row(
                "SELECT truncated_before_seq, dropped_count FROM ring_truncations WHERE workflow_id = ?1",
                [workflow_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            ) {
            Ok(v) => (Some(v.0), v.1),
            Err(rusqlite::Error::QueryReturnedNoRows) => (None, 0),
            Err(error) => return Err(error.into()),
        };
        Ok(RingStats {
            count,
            approx_bytes: bytes,
            oldest_seq: oldest,
            newest_seq: newest,
            truncated_before_seq,
            dropped_count,
        })
    }
}

// --- trim, outbox, bindings, pending requests ---------------------------------

fn map_event(row: &rusqlite::Row) -> rusqlite::Result<calcar_events::WorkflowEvent> {
    Ok(calcar_events::WorkflowEvent {
        event_id: row.get(0)?,
        workflow_id: row.get(7)?,
        provider_session_id: row.get(1)?,
        seq_no: row.get::<_, i64>(2)? as u64,
        occurred_at_millis: row.get(3)?,
        event_type: calcar_events::EventType::from_i32(row.get(4)?)
            .unwrap_or(calcar_events::EventType::Unspecified),
        summary: row.get(5)?,
        detail_pointer: row.get(6)?,
    })
}

/// Trim the ring for one workflow inside the caller's transaction. Keeps the
/// newest events within MAX_RING_EVENTS and MAX_RING_BYTES, never deletes the
/// newest event, and records the cut so replay knows where history starts.
fn trim_ring(tx: &rusqlite::Transaction, workflow_id: &str) -> Result<(), StorageError> {
    let (count, bytes): (i64, i64) = tx.query_row(
        "SELECT COUNT(*), COALESCE(SUM(approx_bytes), 0) FROM workflow_events WHERE workflow_id = ?1",
        [workflow_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let excess_events = (count - MAX_RING_EVENTS).max(0);
    let excess_bytes = (bytes - MAX_RING_BYTES).max(0);
    if excess_events == 0 && excess_bytes == 0 {
        return Ok(());
    }
    let newest: i64 = tx.query_row(
        "SELECT MAX(seq_no) FROM workflow_events WHERE workflow_id = ?1",
        [workflow_id],
        |row| row.get(0),
    )?;
    // Walk the oldest rows and find the seq cutoff that covers both deficits.
    // The newest event always survives even if it alone exceeds the budget.
    let mut stmt = tx.prepare(
        "SELECT seq_no, approx_bytes FROM workflow_events WHERE workflow_id = ?1 AND seq_no < ?2 ORDER BY seq_no ASC",
    )?;
    let mut cutoff: Option<i64> = None;
    let mut need_events = excess_events;
    let mut need_bytes = excess_bytes;
    let mut rows = stmt.query(rusqlite::params![workflow_id, newest])?;
    while let Some(row) = rows.next()? {
        if need_events <= 0 && need_bytes <= 0 {
            break;
        }
        let seq: i64 = row.get(0)?;
        let row_bytes: i64 = row.get(1)?;
        cutoff = Some(seq);
        need_events -= 1;
        need_bytes -= row_bytes;
    }
    drop(rows);
    drop(stmt);
    let Some(cutoff) = cutoff else {
        return Ok(());
    };
    let deleted = tx.execute(
        "DELETE FROM workflow_events WHERE workflow_id = ?1 AND seq_no <= ?2",
        rusqlite::params![workflow_id, cutoff],
    )? as i64;
    tx.execute(
        "INSERT INTO ring_truncations (workflow_id, truncated_before_seq, dropped_count, at_millis)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(workflow_id) DO UPDATE SET
           truncated_before_seq = MAX(truncated_before_seq, excluded.truncated_before_seq),
           dropped_count = dropped_count + excluded.dropped_count,
           at_millis = excluded.at_millis",
        rusqlite::params![workflow_id, cutoff, deleted, calcar_events::now_millis()],
    )?;
    Ok(())
}

// --- outbox -------------------------------------------------------------------

/// One unpublished outbox entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxEntry {
    pub workflow_id: String,
    pub seq_no: i64,
}

impl Storage {
    /// Hand out unpublished entries in order. Marking happens in a separate
    /// call, so a crash between drain and mark replays those entries. Consumers
    /// dedupe on workflow_id plus seq_no, which the event stream keys on anyway.
    pub fn outbox_drain(&self, limit: u32) -> Result<Vec<OutboxEntry>, StorageError> {
        let mut stmt = self.conn.prepare(
            "SELECT workflow_id, seq_no FROM outbox WHERE published_at_millis IS NULL
             ORDER BY enqueued_at_millis ASC, workflow_id ASC, seq_no ASC LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit], |row| {
            Ok(OutboxEntry {
                workflow_id: row.get(0)?,
                seq_no: row.get(1)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, rusqlite::Error>>()
            .map_err(StorageError::from)
    }

    pub fn outbox_mark_published(&self, entries: &[OutboxEntry]) -> Result<usize, StorageError> {
        let mut marked = 0;
        for entry in entries {
            marked += self.conn.execute(
                "UPDATE outbox SET published_at_millis = ?3
                 WHERE workflow_id = ?1 AND seq_no = ?2 AND published_at_millis IS NULL",
                rusqlite::params![entry.workflow_id, entry.seq_no, calcar_events::now_millis()],
            )?;
        }
        Ok(marked)
    }

    pub fn outbox_pending_count(&self) -> Result<i64, StorageError> {
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM outbox WHERE published_at_millis IS NULL",
            [],
            |row| row.get(0),
        )?)
    }
}

// --- session bindings and pending requests ------------------------------------

impl Storage {
    /// Bind a workflow to its provider native session. Restart recovery reads
    /// this to reattach instead of starting over. PRD 23.
    pub fn upsert_session_binding(
        &self,
        workflow_id: &str,
        provider_session_id: &str,
        resume_pointer: Option<&str>,
    ) -> Result<(), StorageError> {
        self.conn.execute(
            "INSERT INTO session_bindings (workflow_id, provider_session_id, resume_pointer, bound_at_millis)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(workflow_id) DO UPDATE SET
               provider_session_id = excluded.provider_session_id,
               resume_pointer = excluded.resume_pointer,
               bound_at_millis = excluded.bound_at_millis",
            rusqlite::params![workflow_id, provider_session_id, resume_pointer, calcar_events::now_millis()],
        )?;
        Ok(())
    }

    pub fn get_session_binding(
        &self,
        workflow_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StorageError> {
        let mut stmt = self.conn.prepare(
            "SELECT provider_session_id, resume_pointer FROM session_bindings WHERE workflow_id = ?1",
        )?;
        let mut rows = stmt.query([workflow_id])?;
        match rows.next()? {
            None => Ok(None),
            Some(row) => Ok(Some((row.get(0)?, row.get(1)?))),
        }
    }

    pub fn create_pending_request(
        &self,
        request_id: &str,
        workflow_id: &str,
        kind: RequestKind,
        expires_at_millis: Option<i64>,
    ) -> Result<(), StorageError> {
        if self.get_workflow(workflow_id)?.is_none() {
            return Err(StorageError::NotFound(format!("workflow {workflow_id}")));
        }
        self.conn.execute(
            "INSERT INTO pending_requests (request_id, workflow_id, kind, state, created_at_millis, expires_at_millis)
             VALUES (?1, ?2, ?3, 1, ?4, ?5)",
            rusqlite::params![request_id, workflow_id, kind as i32, calcar_events::now_millis(), expires_at_millis],
        )?;
        Ok(())
    }

    /// Resolve with single resolve semantics: second resolve and resolve after
    /// expiry are errors. An expired pending request flips to state 3 here so
    /// the table never shows a stale pending row past its deadline.
    pub fn resolve_pending_request(
        &self,
        request_id: &str,
        payload: &str,
    ) -> Result<(), StorageError> {
        let now = calcar_events::now_millis();
        self.conn.execute(
            "UPDATE pending_requests SET state = 3
             WHERE request_id = ?1 AND state = 1 AND expires_at_millis IS NOT NULL AND expires_at_millis <= ?2",
            rusqlite::params![request_id, now],
        )?;
        let updated = self.conn.execute(
            "UPDATE pending_requests SET state = 2, resolved_at_millis = ?2, resolve_payload = ?3
             WHERE request_id = ?1 AND state = 1",
            rusqlite::params![request_id, now, payload],
        )?;
        if updated == 1 {
            return Ok(());
        }
        let state: Option<i32> = self
            .conn
            .query_row(
                "SELECT state FROM pending_requests WHERE request_id = ?1",
                [request_id],
                |row| row.get(0),
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(other),
            })?;
        match state {
            Some(3) => Err(StorageError::Expired(request_id.to_string())),
            Some(_) => Err(StorageError::AlreadyResolved(request_id.to_string())),
            None => Err(StorageError::NotFound(format!("request {request_id}"))),
        }
    }

    /// Flip pending requests past their deadline to expired. Returns the count.
    pub fn expire_pending_requests(&self) -> Result<i64, StorageError> {
        Ok(self.conn.execute(
            "UPDATE pending_requests SET state = 3
             WHERE state = 1 AND expires_at_millis IS NOT NULL AND expires_at_millis <= ?1",
            rusqlite::params![calcar_events::now_millis()],
        )? as i64)
    }
}

// --- tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use calcar_events::{EventType, Provider, WorkflowState};

    fn draft(workflow_id: &str, n: usize, summary: &str) -> EventDraft {
        EventDraft {
            workflow_id: workflow_id.to_string(),
            event_id: format!("ev-{workflow_id}-{n}"),
            provider_session_id: Some("ps-1".into()),
            occurred_at_millis: 1_000 + n as i64,
            event_type: EventType::CommandStarted,
            summary: summary.to_string(),
            detail_pointer: None,
        }
    }

    fn setup() -> Storage {
        let mut storage = Storage::open_in_memory().expect("open");
        storage.migrate().expect("migrate");
        storage
    }

    #[test]
    fn migrate_is_idempotent() {
        let mut storage = setup();
        let first = storage.migrate().expect("second migrate run");
        assert!(
            first.is_empty(),
            "second migrate must apply nothing, got {first:?}"
        );
    }

    #[test]
    fn wal_mode_is_active_on_file_backed_store() {
        let dir = std::env::temp_dir().join(format!("calcar-storage-test-{}", std::process::id()));
        let path = dir.join("agent.db");
        let _ = std::fs::remove_file(&path);
        let storage = Storage::open(&path).expect("open");
        let mode: String = storage
            .conn()
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("pragma");
        assert_eq!(mode.to_lowercase(), "wal");
        drop(storage);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sequences_are_independent_per_workflow() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", Some("ps-a"))
            .expect("create a");
        storage
            .create_workflow("wf-b", Provider::Generic, "B", None)
            .expect("create b");
        for n in 1..=3 {
            let event = storage
                .append_event(draft("wf-a", n, "tick"))
                .expect("append a");
            assert_eq!(event.seq_no, n as u64);
        }
        let event = storage
            .append_event(draft("wf-b", 1, "tick"))
            .expect("append b");
        assert_eq!(event.seq_no, 1, "workflow b starts its own sequence");
    }

    #[test]
    fn every_append_enqueues_exactly_one_outbox_row() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        for n in 1..=5 {
            storage
                .append_event(draft("wf-a", n, "tick"))
                .expect("append");
        }
        assert_eq!(storage.outbox_pending_count().expect("count"), 5);
        let drained = storage.outbox_drain(3).expect("drain");
        assert_eq!(drained.len(), 3);
        assert_eq!(drained[0].seq_no, 1);
        assert_eq!(drained[2].seq_no, 3);
        storage.outbox_mark_published(&drained).expect("mark");
        assert_eq!(storage.outbox_pending_count().expect("count"), 2);
        let again = storage.outbox_drain(10).expect("drain again");
        assert_eq!(
            again.len(),
            2,
            "published entries must not be handed out twice"
        );
    }

    #[test]
    fn ring_trims_to_event_bound_and_marks_the_cut() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        let total = (MAX_RING_EVENTS + 250) as usize;
        for n in 1..=total {
            storage
                .append_event(draft("wf-a", n, "tick"))
                .unwrap_or_else(|error| panic!("append {n}: {error}"));
        }
        let stats = storage.ring_stats("wf-a").expect("stats");
        assert!(
            stats.count <= MAX_RING_EVENTS,
            "ring must respect the event bound, got {}",
            stats.count
        );
        assert!(
            stats.truncated_before_seq.is_some(),
            "trim must record the cut"
        );
        assert!(stats.dropped_count > 0);
        let cut = stats.truncated_before_seq.expect("cut");
        let replay = storage.events_after("wf-a", 0, 1_000_000).expect("replay");
        assert_eq!(replay.len() as i64, stats.count);
        assert_eq!(
            replay[0].seq_no as i64,
            cut + 1,
            "replay starts right after the cut"
        );
        // No duplicates and no gaps inside the kept range.
        for (position, event) in replay.iter().enumerate() {
            assert_eq!(event.seq_no as i64, cut + 1 + position as i64);
        }
    }

    #[test]
    fn oversized_event_never_empties_the_ring() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        for n in 1..=5 {
            storage
                .append_event(draft("wf-a", n, "tick"))
                .expect("append");
        }
        let huge = "x".repeat((MAX_RING_BYTES + 1024) as usize);
        storage
            .append_event(draft("wf-a", 100, &huge))
            .expect("oversized append must still succeed");
        let stats = storage.ring_stats("wf-a").expect("stats");
        assert!(stats.count >= 1, "the newest event must always survive");
        assert_eq!(stats.newest_seq, Some(6));
        let replay = storage.events_after("wf-a", 0, 1_000_000).expect("replay");
        assert_eq!(replay.last().expect("last").seq_no, 6);
    }

    #[test]
    fn terminal_states_never_transition_out() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        storage
            .set_workflow_state("wf-a", WorkflowState::WaitingApproval)
            .expect("non terminal move");
        storage
            .set_workflow_state("wf-a", WorkflowState::Completed)
            .expect("terminal move");
        let error = storage
            .set_workflow_state("wf-a", WorkflowState::Running)
            .expect_err("completed must be final");
        assert!(matches!(error, StorageError::InvalidState(_)));
        // A completed workflow still accepts event reads, and appends still work
        // for late events, but its state row is frozen.
        let row = storage.get_workflow("wf-a").expect("row").expect("exists");
        assert_eq!(row.state, WorkflowState::Completed as i32);
    }

    #[test]
    fn disconnected_projection_never_persists() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        let error = storage
            .set_workflow_state("wf-a", WorkflowState::DisconnectedRunning)
            .expect_err("disconnected is a projection");
        assert!(matches!(error, StorageError::InvalidState(_)));
        let row = storage.get_workflow("wf-a").expect("row").expect("exists");
        assert_eq!(row.state, WorkflowState::Running as i32);
    }

    #[test]
    fn pending_request_resolves_once_then_rejects() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        storage
            .create_pending_request("req-1", "wf-a", RequestKind::Approval, None)
            .expect("create request");
        storage
            .resolve_pending_request("req-1", "approved")
            .expect("first resolve");
        let error = storage
            .resolve_pending_request("req-1", "approved again")
            .expect_err("second resolve must fail");
        assert!(matches!(error, StorageError::AlreadyResolved(_)));
        let error = storage
            .resolve_pending_request("req-missing", "x")
            .expect_err("unknown request");
        assert!(matches!(error, StorageError::NotFound(_)));
    }

    #[test]
    fn expired_request_rejects_resolve_and_flips_state() {
        let storage = setup();
        storage
            .create_workflow("wf-a", Provider::Opencode, "A", None)
            .expect("create");
        // Already past its deadline at creation time.
        storage
            .create_pending_request("req-e", "wf-a", RequestKind::Input, Some(1))
            .expect("create request");
        storage.expire_pending_requests().expect("expire");
        let error = storage
            .resolve_pending_request("req-e", "late answer")
            .expect_err("expired must reject");
        assert!(matches!(error, StorageError::Expired(_)));
    }
}
