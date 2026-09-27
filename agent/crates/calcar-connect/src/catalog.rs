//! Snapshot and header builders over the file-backed store.
//!
//! Failure modes first:
//! 1. Every builder opens the database file fresh and migrates. A corrupt
//!    or locked file fails the request with 500, never with half a body.
//! 2. `WorkflowState` ints the store does not know become
//!    `"unknown_<n>"`, which the phone chips render raw. Never invent a
//!    lifecycle string the store did not persist.
//! 3. The [`Registry`] is a hint file, not truth: ids this server touched,
//!    re-validated per request through [`WorkflowManager`]. A corrupt
//!    registry file loads as empty (list shrinks, then self-heals); a save
//!    failure is logged to stderr and the in-memory set still serves.
//! 4. Activity serves the newest [`ACTIVITY_CAP`] events; the ring underneath
//!    holds 5000, so one fetch with room to spare covers the whole ring and
//!    `last_seq_no` is the true high-water mark even when the tail is cut.
//! 5. Chat, terminal, and files have no store seam in P4, so they serve
//!    empty with honest totals (0 / false). The phone re-caps on insert
//!    anyway; the caps below mirror `caps.dart` so the agent side already
//!    matches when those seams land.

use std::collections::BTreeSet;

use calcar_events::WorkflowState;
use calcar_workflow::WorkflowManager;

use crate::config::ConnectConfig;
use crate::json::{self, Value};

/// Newest activity rows kept per workflow snapshot. Mirrors `kActivityCap`.
pub const ACTIVITY_CAP: usize = 500;
/// Ring read sized past `MAX_RING_EVENTS` (5000) so the tail fetch never
/// misses the high-water mark.
pub const RING_READ_LIMIT: u32 = 5500;

/// Stored state int to the lifecycle string the phone chips render.
pub fn status_str(state: i32) -> String {
    match WorkflowState::from_i32(state) {
        Some(WorkflowState::Running) => "running".to_string(),
        Some(WorkflowState::WaitingInput) => "waiting_input".to_string(),
        Some(WorkflowState::WaitingApproval) => "waiting_approval".to_string(),
        Some(WorkflowState::Completed) => "completed".to_string(),
        Some(WorkflowState::Failed) => "failed".to_string(),
        Some(WorkflowState::Stopped) => "stopped".to_string(),
        _ => format!("unknown_{state}"),
    }
}

/// One approval outcome resolved through this server. Title, detail, and
/// expiry are empty/zero here: the store resolve path carries only the
/// decision, and inventing metadata would be worse than omitting it. Full
/// pending-approval rows await the P5 permission-manager readout seam.
#[derive(Debug, Clone)]
pub struct ResolvedApproval {
    pub approval_id: String,
    pub workflow_id: String,
    pub resolution: String,
}

/// Ids this server has touched, persisted beside the database. Rebuilt
/// from nothing on loss; every id is re-validated before it shapes a
/// response.
#[derive(Debug, Default)]
pub struct Registry {
    pub workflows: BTreeSet<String>,
    pub approvals: Vec<ResolvedApproval>,
}

impl Registry {
    pub fn path(config: &ConnectConfig) -> std::path::PathBuf {
        config.state_dir().join("calcar-connect-known.json")
    }

    /// Load the sidecar; any failure (missing, corrupt, wrong shape) is an
    /// empty registry, never a startup or request error.
    pub fn load(config: &ConnectConfig) -> Self {
        let text = std::fs::read_to_string(Self::path(config)).unwrap_or_default();
        if text.trim().is_empty() {
            return Self::default();
        }
        let parsed = json::parse(&text).unwrap_or(Value::Null);
        Self::from_value(&parsed)
    }

    fn from_value(value: &Value) -> Self {
        let mut registry = Self::default();
        let Value::Obj(map) = value else {
            return registry;
        };
        if let Some(Value::Arr(ids)) = map.get("workflows") {
            for id in ids {
                if let Value::Str(text) = id {
                    if !text.is_empty() {
                        registry.workflows.insert(text.clone());
                    }
                }
            }
        }
        if let Some(Value::Arr(rows)) = map.get("approvals") {
            for row in rows {
                let approval_id = row.str_field("approval_id").unwrap_or_default();
                let workflow_id = row.str_field("workflow_id").unwrap_or_default();
                let resolution = row.str_field("resolution").unwrap_or_default();
                if !approval_id.is_empty() && !workflow_id.is_empty() {
                    registry.approvals.push(ResolvedApproval {
                        approval_id: approval_id.to_string(),
                        workflow_id: workflow_id.to_string(),
                        resolution: if resolution.is_empty() {
                            "approved".to_string()
                        } else {
                            resolution.to_string()
                        },
                    });
                }
            }
        }
        registry
    }

    /// Best-effort persist. Failure is logged by the caller; the
    /// in-memory set keeps serving either way.
    pub fn save(&self, config: &ConnectConfig) -> std::io::Result<()> {
        let workflows: Vec<Value> = self.workflows.iter().cloned().map(Value::Str).collect();
        let approvals: Vec<Value> = self
            .approvals
            .iter()
            .map(|row| {
                json::obj(vec![
                    ("approval_id", Value::Str(row.approval_id.clone())),
                    ("workflow_id", Value::Str(row.workflow_id.clone())),
                    ("resolution", Value::Str(row.resolution.clone())),
                ])
            })
            .collect();
        let text = json::render(&json::obj(vec![
            ("workflows", Value::Arr(workflows)),
            ("approvals", Value::Arr(approvals)),
        ]));
        std::fs::write(Self::path(config), text)
    }

    pub fn touch_workflow(&mut self, workflow_id: &str) {
        if !workflow_id.is_empty() {
            self.workflows.insert(workflow_id.to_string());
        }
    }

    pub fn record_approval(&mut self, row: ResolvedApproval) {
        self.approvals
            .retain(|kept| kept.approval_id != row.approval_id);
        self.approvals.push(row);
    }
}

/// Open the file-backed store for one request. Owns migration so a first
/// boot against a fresh path just works.
pub fn open_manager(
    config: &ConnectConfig,
) -> Result<WorkflowManager, calcar_workflow::LifecycleError> {
    WorkflowManager::open(&config.db_path)
}

/// GET /v1/agent/computers/{id}: header plus workflow rows. Rows are the
/// registry ids intersected with live store reads; a row whose lookup
/// misses is dropped, never blanked, matching the phone's own rule.
pub fn computer_body(
    config: &ConnectConfig,
    registry: &Registry,
    manager: &WorkflowManager,
    now_millis: i64,
) -> Value {
    let mut rows = Vec::new();
    for workflow_id in &registry.workflows {
        let Ok(Some(row)) = manager.get_workflow(workflow_id) else {
            continue;
        };
        if row.workflow_id.is_empty() {
            continue;
        }
        rows.push(json::obj(vec![
            ("workflow_id", Value::Str(row.workflow_id)),
            ("computer_id", Value::Str(config.computer_id.clone())),
            ("title", Value::Str(row.title)),
            ("status", Value::Str(status_str(row.state))),
        ]));
    }
    json::obj(vec![
        ("device_id", Value::Str(config.computer_id.clone())),
        ("display_name", Value::Str(config.display_name.clone())),
        ("online", Value::Bool(true)),
        ("last_seen_millis", Value::Int(now_millis)),
        ("workflows", Value::Arr(rows)),
    ])
}

/// GET /v1/agent/computers/{id}/sysinfo: the four lazy fields the detail
/// screen renders. Values are provisioned in config; unprovisioned reads
/// blank rather than guessed.
pub fn sysinfo_body(config: &ConnectConfig) -> Value {
    json::obj(vec![
        ("cpu", Value::Str(config.cpu.clone())),
        ("ram", Value::Str(config.ram.clone())),
        ("gpu", Value::Str(config.gpu.clone())),
        ("disk", Value::Str(config.disk.clone())),
    ])
}

/// GET /v1/agent/devices?user_id=: this managed computer as the one device
/// row. Keys mirror `Device.fromJson`; `revoked` is always false here
/// because a revoked agent would fail auth before reaching this handler.
pub fn devices_body(config: &ConnectConfig) -> Value {
    json::obj(vec![(
        "devices",
        Value::Arr(vec![json::obj(vec![
            ("device_id", Value::Str(config.computer_id.clone())),
            ("role", Value::Str("computer".to_string())),
            ("display_name", Value::Str(config.display_name.clone())),
            ("pubkey_b64", Value::Str(config.pubkey_b64.clone())),
            ("fingerprint", Value::Str(config.fingerprint.clone())),
            ("revoked", Value::Bool(false)),
            ("authorized_by", Value::Str(config.owner_device_id.clone())),
        ])]),
    )])
}

/// GET /v1/agent/computers/{computer}/workflows/{workflow}: full snapshot.
/// Activity maps the real event ring; chat, terminal, and files are empty
/// until their store seams land; approvals show outcomes resolved through
/// this server. `None` when the workflow id is unknown.
pub fn workflow_snapshot_body(
    registry: &Registry,
    manager: &WorkflowManager,
    computer_id: &str,
    workflow_id: &str,
) -> Result<Option<Value>, calcar_workflow::LifecycleError> {
    let row = match manager.get_workflow(workflow_id)? {
        Some(row) => row,
        None => return Ok(None),
    };
    let events = manager.events_since(workflow_id, 0, RING_READ_LIMIT)?;
    let last_seq_no = events.last().map(|event| event.seq_no as i64).unwrap_or(0);
    let tail_start = events.len().saturating_sub(ACTIVITY_CAP);
    let activity: Vec<Value> = events[tail_start..]
        .iter()
        .map(|event| {
            json::obj(vec![
                ("event_id", Value::Str(event.event_id.clone())),
                ("event_type", Value::Int(event.event_type as i32 as i64)),
                ("summary", Value::Str(event.summary.clone())),
                ("occurred_at_millis", Value::Int(event.occurred_at_millis)),
                ("seq_no", Value::Int(event.seq_no as i64)),
            ])
        })
        .collect();
    let approvals: Vec<Value> = registry
        .approvals
        .iter()
        .filter(|row| row.workflow_id == workflow_id)
        .map(|row| {
            json::obj(vec![
                ("approval_id", Value::Str(row.approval_id.clone())),
                ("title", Value::Str(String::new())),
                ("detail", Value::Str(String::new())),
                ("expires_at_millis", Value::Int(0)),
                ("resolution", Value::Str(row.resolution.clone())),
                ("destructive", Value::Bool(false)),
            ])
        })
        .collect();
    Ok(Some(json::obj(vec![
        ("workflow_id", Value::Str(row.workflow_id)),
        ("computer_id", Value::Str(computer_id.to_string())),
        ("status", Value::Str(status_str(row.state))),
        ("last_seq_no", Value::Int(last_seq_no)),
        ("activity", Value::Arr(activity)),
        ("chat", Value::Arr(Vec::new())),
        ("terminal_lines", Value::Arr(Vec::new())),
        ("terminal_total_lines", Value::Int(0)),
        ("files", Value::Arr(Vec::new())),
        ("files_truncated", Value::Bool(false)),
        ("approvals", Value::Arr(approvals)),
    ])))
}
