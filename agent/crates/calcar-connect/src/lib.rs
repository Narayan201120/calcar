//! Agent connection manager: the sync HTTP slice the phone calls (PLAN P7).
//!
//! Failure modes first, so the merge step and every caller wire around them:
//! 1. Bearer token missing or wrong is 401 with an empty body. No hint, no
//!    JSON, nothing to fingerprint. The token is read once from the file
//!    named in the config at [`ConnectServer::new`]; a missing or empty
//!    token file fails startup with no server.
//! 2. Unknown computer id, workflow id, or approval request id is 404 with
//!    the same envelope shape. Ids are never echoed beyond the URL id the
//!    caller already sent, so enumeration learns nothing.
//! 3. Malformed JSON or missing required fields is 400 MALFORMED. Non-UTF8
//!    bodies are 400. Bodies over 1 MiB are 413 and never buffered.
//! 4. Both POST routes require `X-Request-ID` and require it to equal the
//!    body id (`approval_id` / `input_id`). Missing or mismatched keys are
//!    400: a retried send after a drop must apply at most once, and the key
//!    is what makes the retry safe.
//! 5. Approval resolve is single-wins from the store: duplicate resolve is
//!    409 ALREADY_RESOLVED, resolve after expiry is 410 EXPIRED.
//! 6. Input delivery dedupes per (workflow, UUID) in the store. A repeated
//!    UUID is 200 with `outcome:"duplicate"` and runs nothing, so a retry
//!    after a 60 second drop duplicates nothing.
//! 7. Inputs for interactive providers (anything but generic) are 501
//!    CONPTY_UNAVAILABLE with a stable schema. The idempotency key is NOT
//!    consumed on this path: the router runs only after the provider check,
//!    so the same `input_id` stays retryable once the ConPTY gate greens.
//! 8. Generic inputs run through [`PlainChild`](calcar_pty::plain::PlainChild)
//!    with a bounded wait. Timeout kills the whole job tree and is 504
//!    EXEC_TIMEOUT. A failure to record the run after it executed is 500
//!    EXEC_RECORD_FAILED: the command ran, the event ring does not say so.
//! 9. Storage faults are 500 INTERNAL. Requests run sequentially on one
//!    thread with one open connection at a time; two agent processes sharing
//!    one database file would fork the truth, so exactly one may open it.
//! 10. The computer snapshot lists only workflows this server has touched
//!     (snapshot, approval, or input) since its registry file was created.
//!     Rows are always re-validated against the store, so the list never
//!     shows a deleted workflow, but a workflow created out of band stays
//!     invisible until first touch. Registry loss just shrinks the list; it
//!     self-heals on next touch. The permanent fix is a `list_workflows`
//!     query on the store (merge-owned, existing-file edit, exact SQL is in
//!     the crate report).
//! 11. Chat, terminal, and files buffers are empty in this slice: the P4
//!     store has no seam for them yet. Caps (500 activity, 300 chat, 2000
//!     terminal lines, 50 files / 200 KB) are already mirrored here so the
//!     agent side of the contract holds when those seams land. Approvals in
//!     the snapshot show only outcomes resolved through this server; pending
//!     approvals created by adapters need the pending-list seam (also
//!     merge-owned, spelled out in the report).
//! 12. Logs carry method, path, and status only. Token, bodies, command
//!     output, and prompts never reach logs, errors, or metrics (P7 privacy
//!     audit). Error messages are short stable strings, never data.
//!
//! Endpoint set, exactly what `agent_channel.dart` calls plus the device
//! row the My Computers list needs:
//! - GET  /v1/agent/devices?user_id=
//! - GET  /v1/agent/computers/{id}
//! - GET  /v1/agent/computers/{id}/sysinfo
//! - GET  /v1/agent/computers/{id}/workflows/{id}
//! - POST /v1/agent/workflows/{id}/approvals
//! - POST /v1/agent/workflows/{id}/inputs
//!
//! JSON keys match `agent_channel.dart` and `_buffersFrom` exactly:
//! snake_case wire names, `last_seq_no` high-water mark, cap totals
//! (`terminal_total_lines`, `files_truncated`), approvals keyed by
//! `approval_id`.

#![deny(warnings)]

pub mod auth;
pub mod catalog;
pub mod config;
pub mod exec;
pub mod json;
pub mod server;

pub use config::{ConnectConfig, ConnectError};
pub use server::ConnectServer;
