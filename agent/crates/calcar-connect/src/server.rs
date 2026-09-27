//! Sync HTTP server on 127.0.0.1 with a configurable port.
//!
//! Failure modes first (server-level; handler-level modes live in `lib.rs`
//! and per module):
//! 1. Bind failure (port taken, no loopback) fails `run` before serving.
//!    There is no fallback port: a silent port move would strand the phone.
//! 2. Requests run sequentially on the accept thread. One phone, one
//!    server, no lock: throughput is bounded but the single-writer store
//!    invariant holds without contention. A second concurrent client waits.
//! 3. The store is opened fresh per request phase and each handle is
//!    dropped (by scope) before the next opens. Only one connection exists
//!    at a time, so `SQLITE_BUSY` from within this process cannot happen;
//!    a busy file means another process holds the database, and that
//!    request is 500.
//! 4. The provider check runs BEFORE the input router on POST inputs, so a
//!    501 for interactive providers never consumes the idempotency key.
//! 5. Approval resolve checks workflow existence first (404
//!    WORKFLOW_UNKNOWN), then resolves by `approval_id` directly. The store
//!    request id IS the approval id by thin-slice convention; a mismatch
//!    between URL workflow and the row's workflow is not verified (P5
//!    permission manager owns that binding, reported as a merge seam).
//! 6. Generic execution drops the store connection before spawn and
//!    reopens after, so a long run holds no database lock.

use std::time::Duration;

use calcar_events::{now_millis, EventType, Provider};
use calcar_storage::{EventDraft, Storage, StorageError};
use calcar_workflow::{InputRouter, SessionManager};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

use crate::auth::bearer_ok;
use crate::catalog::{self, Registry, ResolvedApproval};
use crate::config::{read_token, ConnectConfig, ConnectError};
use crate::exec::{self, ExecError};
use crate::json::{self, Value};

/// Request bodies over this many bytes are refused unread.
const MAX_BODY_BYTES: usize = 1024 * 1024;

type BodyResponse = Response<std::io::Cursor<Vec<u8>>>;

/// The sync connection manager. Owns config, the bearer token, and the
/// touched-workflow registry. Serves exactly the six routes in `lib.rs`.
pub struct ConnectServer {
    config: ConnectConfig,
    token: String,
    registry: Registry,
}

impl ConnectServer {
    /// Read the token file and load the registry sidecar. Fails on any
    /// config or token problem with no server started.
    pub fn new(config: ConnectConfig) -> Result<Self, ConnectError> {
        let token = read_token(&config.token_file)?;
        let registry = Registry::load(&config);
        Ok(Self {
            config,
            token,
            registry,
        })
    }

    pub fn listen_addr(&self) -> String {
        format!("127.0.0.1:{}", self.config.port)
    }

    /// Accept loop. Sequential by design (see module docs). Returns only
    /// on bind or accept-loop failure.
    pub fn run(mut self) -> Result<(), ConnectError> {
        let addr = self.listen_addr();
        let server = Server::http(&addr).map_err(|error| ConnectError::Bind {
            addr: addr.clone(),
            detail: error.to_string(),
        })?;
        eprintln!("calcar-connect listening on {addr}");
        for mut request in server.incoming_requests() {
            let method = request.method().clone();
            let url = request.url().to_string();
            let response = self.reply(&mut request);
            let status = response.status_code().0;
            eprintln!("{} {} -> {status}", method.as_str(), split_path(&url).0);
            if let Err(error) = request.respond(response) {
                eprintln!("respond failed: {error}");
            }
        }
        Ok(())
    }

    fn reply(&mut self, request: &mut Request) -> BodyResponse {
        if !bearer_ok(request, &self.token) {
            // 401 carries no body details by contract.
            return Response::from_string(String::new()).with_status_code(StatusCode(401));
        }
        let method = request.method().clone();
        let url = request.url().to_string();
        let (path, query) = split_path(&url);
        let segments = path_segments(&path);
        let parts: Vec<&str> = segments.iter().map(String::as_str).collect();
        match (method, parts.as_slice()) {
            (Method::Get, ["v1", "agent", "devices"]) => self.handle_devices(&query),
            (Method::Get, ["v1", "agent", "computers", id]) => self.handle_computer(id),
            (Method::Get, ["v1", "agent", "computers", id, "sysinfo"]) => self.handle_sysinfo(id),
            (Method::Get, ["v1", "agent", "computers", computer, "workflows", workflow]) => {
                self.handle_workflow_snapshot(computer, workflow)
            }
            (Method::Post, ["v1", "agent", "workflows", workflow, "approvals"]) => {
                self.handle_approval(request, workflow)
            }
            (Method::Post, ["v1", "agent", "workflows", workflow, "inputs"]) => {
                self.handle_input(request, workflow)
            }
            _ => error_body(404, "NOT_FOUND", "unknown route"),
        }
    }

    fn handle_devices(&self, query: &str) -> BodyResponse {
        match query_value(query, "user_id") {
            Some(user) if !user.is_empty() => json_ok(&catalog::devices_body(&self.config)),
            _ => error_body(400, "MISSING_USER_ID", "user_id query is required"),
        }
    }

    fn handle_computer(&mut self, id: &str) -> BodyResponse {
        if id != self.config.computer_id {
            return error_body(404, "COMPUTER_UNKNOWN", "unknown computer");
        }
        let manager = match catalog::open_manager(&self.config) {
            Ok(manager) => manager,
            Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
        };
        json_ok(&catalog::computer_body(
            &self.config,
            &self.registry,
            &manager,
            now_millis(),
        ))
    }

    fn handle_sysinfo(&self, id: &str) -> BodyResponse {
        if id != self.config.computer_id {
            return error_body(404, "COMPUTER_UNKNOWN", "unknown computer");
        }
        json_ok(&catalog::sysinfo_body(&self.config))
    }

    fn handle_workflow_snapshot(&mut self, computer: &str, workflow: &str) -> BodyResponse {
        if computer != self.config.computer_id {
            return error_body(404, "COMPUTER_UNKNOWN", "unknown computer");
        }
        let manager = match catalog::open_manager(&self.config) {
            Ok(manager) => manager,
            Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
        };
        match catalog::workflow_snapshot_body(&self.registry, &manager, computer, workflow) {
            Ok(Some(body)) => {
                self.registry.touch_workflow(workflow);
                self.persist_registry();
                json_ok(&body)
            }
            Ok(None) => error_body(404, "WORKFLOW_UNKNOWN", "unknown workflow"),
            Err(error) => error_body(500, "INTERNAL", &short_error(&error.to_string())),
        }
    }

    fn handle_approval(&mut self, request: &mut Request, workflow: &str) -> BodyResponse {
        let key = request_id_of(request);
        let body = match read_body(request) {
            Ok(body) => body,
            Err((status, code, message)) => return error_body(status, code, message),
        };
        let parsed = match parse_object(&body) {
            Some(value) => value,
            None => return error_body(400, "MALFORMED", "body must be a JSON object"),
        };
        let (Some(approval_id), Some(allow)) =
            (parsed.str_field("approval_id"), parsed.bool_field("allow"))
        else {
            return error_body(400, "MALFORMED", "approval_id and allow are required");
        };
        if approval_id.is_empty() {
            return error_body(400, "MALFORMED", "approval_id must not be empty");
        }
        if key.as_deref() != Some(approval_id) {
            // The idempotency key binds to the approval being resolved.
            return error_body(400, "MALFORMED", "X-Request-ID must equal approval_id");
        }
        let known = {
            let manager = match catalog::open_manager(&self.config) {
                Ok(manager) => manager,
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            };
            match manager.get_workflow(workflow) {
                Ok(row) => row.is_some(),
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            }
        };
        if !known {
            return error_body(404, "WORKFLOW_UNKNOWN", "unknown workflow");
        }
        let storage = match open_storage(&self.config) {
            Ok(storage) => storage,
            Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
        };
        let payload = if allow { "approved" } else { "rejected" };
        match storage.resolve_pending_request(approval_id, payload) {
            Ok(()) => {
                self.registry.touch_workflow(workflow);
                self.registry.record_approval(ResolvedApproval {
                    approval_id: approval_id.to_string(),
                    workflow_id: workflow.to_string(),
                    resolution: payload.to_string(),
                });
                self.persist_registry();
                json_ok(&json::obj(vec![
                    ("approval_id", Value::Str(approval_id.to_string())),
                    ("resolution", Value::Str(payload.to_string())),
                ]))
            }
            Err(StorageError::NotFound(_)) => {
                error_body(404, "APPROVAL_UNKNOWN", "unknown approval")
            }
            Err(StorageError::AlreadyResolved(_)) => {
                error_body(409, "ALREADY_RESOLVED", "approval already resolved")
            }
            Err(StorageError::Expired(_)) => error_body(410, "EXPIRED", "approval expired"),
            Err(error) => error_body(500, "INTERNAL", &short_error(&error.to_string())),
        }
    }

    fn handle_input(&mut self, request: &mut Request, workflow: &str) -> BodyResponse {
        let key = request_id_of(request);
        let body = match read_body(request) {
            Ok(body) => body,
            Err((status, code, message)) => return error_body(status, code, message),
        };
        let parsed = match parse_object(&body) {
            Some(value) => value,
            None => return error_body(400, "MALFORMED", "body must be a JSON object"),
        };
        let (Some(input_id), Some(text), Some(destructive)) = (
            parsed.str_field("input_id"),
            parsed.str_field("body"),
            parsed.bool_field("destructive"),
        ) else {
            return error_body(
                400,
                "MALFORMED",
                "input_id, body, and destructive are required",
            );
        };
        if key.as_deref() != Some(input_id) {
            return error_body(400, "MALFORMED", "X-Request-ID must equal input_id");
        }
        if !exec::check_input_id(input_id) {
            return error_body(400, "MALFORMED", "input_id uses an unsafe alphabet");
        }
        if text.is_empty() {
            return error_body(400, "MALFORMED", "body must not be empty");
        }
        let text = text.to_string();
        let input_id = input_id.to_string();
        // Provider gate first: interactive inputs are 501 WITHOUT consuming
        // the idempotency key, so the same input_id stays retryable.
        let (provider, session_id) = {
            let manager = match catalog::open_manager(&self.config) {
                Ok(manager) => manager,
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            };
            match manager.get_workflow(workflow) {
                Ok(Some(row)) => (
                    calcar_events::Provider::from_i32(row.provider),
                    row.provider_session_id.clone(),
                ),
                Ok(None) => return error_body(404, "WORKFLOW_UNKNOWN", "unknown workflow"),
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            }
        };
        if provider != Some(Provider::Generic) {
            let bound = {
                let storage = match open_storage(&self.config) {
                    Ok(storage) => storage,
                    Err(error) => {
                        return error_body(500, "INTERNAL", &short_error(&error.to_string()));
                    }
                };
                SessionManager::new(&storage)
                    .lookup(workflow)
                    .ok()
                    .flatten()
                    .is_some()
            };
            return json_status(
                501,
                &json::obj(vec![
                    ("code", Value::Str("CONPTY_UNAVAILABLE".to_string())),
                    (
                        "message",
                        Value::Str(
                            "interactive input needs ConPTY, which is not green".to_string(),
                        ),
                    ),
                    ("workflow_id", Value::Str(workflow.to_string())),
                    ("has_binding", Value::Bool(bound)),
                ]),
            );
        }
        // Generic path: dedupe through the router, then execute with no
        // store handle open.
        let delivered = {
            let storage = match open_storage(&self.config) {
                Ok(storage) => storage,
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            };
            let mut router = InputRouter::new(&storage);
            match router.deliver(workflow, &input_id, &text) {
                Err(StorageError::NotFound(_)) => {
                    return error_body(404, "WORKFLOW_UNKNOWN", "unknown workflow");
                }
                Err(StorageError::InvalidState(_)) => {
                    return error_body(400, "MALFORMED", "invalid workflow or input id");
                }
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
                Ok(outcome) => outcome == calcar_workflow::RouteOutcome::Delivered,
            }
        };
        if !delivered {
            self.registry.touch_workflow(workflow);
            self.persist_registry();
            return json_ok(&json::obj(vec![
                ("input_id", Value::Str(input_id.clone())),
                ("outcome", Value::Str("duplicate".to_string())),
            ]));
        }
        let timeout = Duration::from_secs(self.config.exec_timeout_secs);
        let outcome = match exec::run_generic(&text, timeout) {
            Ok(outcome) => outcome,
            Err(ExecError::Timeout) => {
                return error_body(504, "EXEC_TIMEOUT", "command timed out and was killed");
            }
            Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
        };
        // Record after the run: tail file plus ring events. A record failure
        // here is 500 AFTER execution (failure mode 8 in lib.rs).
        let record = {
            let storage = match open_storage(&self.config) {
                Ok(storage) => storage,
                Err(error) => return error_body(500, "INTERNAL", &short_error(&error.to_string())),
            };
            record_run(
                &storage,
                &self.config,
                workflow,
                &input_id,
                session_id,
                &outcome,
                destructive,
            )
        };
        let truncated = match record {
            Ok(truncated) => truncated,
            Err(message) => return error_body(500, "EXEC_RECORD_FAILED", &message),
        };
        self.registry.touch_workflow(workflow);
        self.persist_registry();
        json_ok(&json::obj(vec![
            ("input_id", Value::Str(input_id)),
            ("outcome", Value::Str("delivered".to_string())),
            ("exit_code", Value::Int(i64::from(outcome.exit_code))),
            ("truncated", Value::Bool(truncated)),
        ]))
    }

    fn persist_registry(&self) {
        if let Err(error) = self.registry.save(&self.config) {
            // Hint-only file: log and keep serving from memory.
            eprintln!("registry save failed: {error}");
        }
    }
}

/// Append the started/completed pair behind one generic run. Returns the
/// truncation flag shown to the phone.
fn record_run(
    storage: &Storage,
    config: &ConnectConfig,
    workflow: &str,
    input_id: &str,
    session_id: Option<String>,
    outcome: &exec::ExecOutcome,
    destructive: bool,
) -> Result<bool, String> {
    let (tail_path, tail_cut) = exec::write_tail(&config.state_dir(), workflow, input_id, outcome)
        .map_err(|error| short_error(&error.to_string()))?;
    let destructive_mark = if destructive { " (destructive)" } else { "" };
    let completed_summary = format!(
        "input {input_id} completed with exit code {}{destructive_mark}{}",
        outcome.exit_code,
        if tail_cut { " (truncated)" } else { "" }
    );
    let started = EventDraft {
        workflow_id: workflow.to_string(),
        event_id: format!("input-{input_id}-started"),
        provider_session_id: session_id.clone(),
        occurred_at_millis: now_millis(),
        event_type: EventType::CommandStarted,
        summary: format!("input {input_id} applied{destructive_mark}"),
        detail_pointer: None,
    };
    let completed = EventDraft {
        workflow_id: workflow.to_string(),
        event_id: format!("input-{input_id}-completed"),
        provider_session_id: session_id,
        occurred_at_millis: now_millis(),
        event_type: EventType::CommandCompleted,
        summary: completed_summary,
        detail_pointer: Some(tail_path),
    };
    storage
        .append_event(started)
        .map_err(|error| short_error(&error.to_string()))?;
    storage
        .append_event(completed)
        .map_err(|error| short_error(&error.to_string()))?;
    Ok(tail_cut)
}

/// Open the file-backed store for router, session, and resolve calls.
fn open_storage(config: &ConnectConfig) -> Result<Storage, StorageError> {
    let mut storage = Storage::open(&config.db_path)?;
    storage.migrate()?;
    Ok(storage)
}

/// Split `path?query` from `Request::url()`.
fn split_path(url: &str) -> (String, String) {
    match url.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (url.to_string(), String::new()),
    }
}

/// Path segments with percent-decoding. Empty segments are dropped, so a
/// trailing slash never routes.
fn path_segments(path: &str) -> Vec<String> {
    path.split('/')
        .filter(|part| !part.is_empty())
        .map(percent_decode)
        .collect()
}

fn percent_decode(part: &str) -> String {
    let bytes = part.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let triple = bytes.get(index + 1..index + 3);
        if bytes[index] == b'%' {
            if let Some([hi, lo]) = triple.map(|pair| [pair[0], pair[1]]) {
                if let (Some(hi), Some(lo)) = (hex_val(hi), hex_val(lo)) {
                    out.push(hi << 4 | lo);
                    index += 3;
                    continue;
                }
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// First `user_id`-style query value, percent-decoded.
fn query_value(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        if percent_decode(name) == key {
            return Some(percent_decode(value));
        }
    }
    None
}

/// The caller-supplied idempotency key. Absent header is None, which never
/// equals a body id, so it fails closed at the binding check.
fn request_id_of(request: &Request) -> Option<String> {
    for header in request.headers() {
        if header.field.equiv("X-Request-ID") {
            let value = header.value.as_str().trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

/// Read the full body up to the cap. The triple is the status, code, and
/// message the caller reports: 413 past the cap, 400 on IO or non-UTF8.
fn read_body(request: &mut Request) -> Result<String, (u16, &'static str, &'static str)> {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    let reader = request.as_reader();
    loop {
        match std::io::Read::read(&mut *reader, &mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if bytes.len() + n > MAX_BODY_BYTES {
                    return Err((413, "PAYLOAD_TOO_LARGE", "body exceeds 1 MiB"));
                }
                bytes.extend_from_slice(&chunk[..n]);
            }
            Err(_) => return Err((400, "MALFORMED", "unreadable body")),
        }
    }
    String::from_utf8(bytes).map_err(|_| (400, "MALFORMED", "body must be UTF-8"))
}

/// Parse a body that must be one JSON object.
fn parse_object(body: &str) -> Option<Value> {
    let value = json::parse(body).ok()?;
    match value {
        Value::Obj(_) => Some(value),
        _ => None,
    }
}

/// Errors carry short stable strings only. The store error text can name
/// paths and ids, so it is reduced to its first line and capped; never
/// logged with bodies.
fn short_error(detail: &str) -> String {
    detail
        .lines()
        .next()
        .unwrap_or("error")
        .chars()
        .take(160)
        .collect()
}

fn json_ok(body: &Value) -> BodyResponse {
    json_status(200, body)
}

fn json_status(status: u16, body: &Value) -> BodyResponse {
    let response = Response::from_string(json::render(body)).with_status_code(StatusCode(status));
    match Header::from_bytes("Content-Type", "application/json") {
        Ok(header) => response.with_header(header),
        Err(_) => response,
    }
}

fn error_body(status: u16, code: &str, message: &str) -> BodyResponse {
    json_status(
        status,
        &json::obj(vec![
            ("code", Value::Str(code.to_string())),
            ("message", Value::Str(message.to_string())),
        ]),
    )
}
