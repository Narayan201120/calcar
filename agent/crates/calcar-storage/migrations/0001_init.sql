-- Agent local store. One SQLite file per computer, WAL mode, single writer
-- (the storage layer is the only module that touches this database).
-- PLAN P4, PRD 24. Provider transcripts and project files stay with the
-- provider; this store holds Calcar owned state only.
-- All timestamps are int64 unix millis, UTC.

CREATE TABLE IF NOT EXISTS schema_migrations (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  applied_at_millis INTEGER NOT NULL
);

-- Primary user facing unit hiding N OS processes. workflows.proto Workflow.
CREATE TABLE IF NOT EXISTS workflows (
  workflow_id TEXT PRIMARY KEY,
  provider INTEGER NOT NULL,             -- calcar_events::Provider discriminant
  state INTEGER NOT NULL,                -- calcar_events::WorkflowState discriminant
  title TEXT NOT NULL,
  provider_session_id TEXT,
  created_at_millis INTEGER NOT NULL,
  updated_at_millis INTEGER NOT NULL,
  CHECK (state NOT IN (0, 7))            -- unspecified and disconnected never persist
);

-- Bounded event ring per workflow. PLAN P4: trim to the newest events within
-- max_events or max_bytes, write one truncated marker, keep seq_no monotonic.
-- events.proto WorkflowEvent.
CREATE TABLE IF NOT EXISTS workflow_events (
  workflow_id TEXT NOT NULL REFERENCES workflows(workflow_id) ON DELETE CASCADE,
  seq_no INTEGER NOT NULL,               -- per workflow monotonic, starts at 1
  event_id TEXT NOT NULL,
  provider_session_id TEXT,
  type INTEGER NOT NULL,                 -- calcar_events::EventType discriminant
  occurred_at_millis INTEGER NOT NULL,
  summary TEXT NOT NULL,
  detail_pointer TEXT,
  approx_bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (workflow_id, seq_no)
);
CREATE INDEX IF NOT EXISTS workflow_events_time
  ON workflow_events(workflow_id, occurred_at_millis);

-- Events waiting for the connection manager to publish. Drain order is seq
-- order per workflow. PLAN P4.
CREATE TABLE IF NOT EXISTS outbox (
  workflow_id TEXT NOT NULL,
  seq_no INTEGER NOT NULL,
  enqueued_at_millis INTEGER NOT NULL,
  published_at_millis INTEGER,
  PRIMARY KEY (workflow_id, seq_no)
);

-- Provider session binding so a restarted agent reattaches to the same
-- provider session. PLAN P4 restart recovery. PRD 23.
CREATE TABLE IF NOT EXISTS session_bindings (
  workflow_id TEXT PRIMARY KEY REFERENCES workflows(workflow_id) ON DELETE CASCADE,
  provider_session_id TEXT NOT NULL,
  resume_pointer TEXT,
  bound_at_millis INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS ring_truncations (
  workflow_id TEXT PRIMARY KEY,
  truncated_before_seq INTEGER NOT NULL,
  dropped_count INTEGER NOT NULL DEFAULT 0,
  at_millis INTEGER NOT NULL
);

-- Pending input and approval requests. Single resolve wins; expired or
-- resolved requests reject further resolves. PLAN P4, PRD 21.
CREATE TABLE IF NOT EXISTS pending_requests (
  request_id TEXT PRIMARY KEY,
  workflow_id TEXT NOT NULL REFERENCES workflows(workflow_id) ON DELETE CASCADE,
  kind INTEGER NOT NULL CHECK (kind IN (1, 2)),      -- 1 input, 2 approval
  state INTEGER NOT NULL CHECK (state IN (1, 2, 3)), -- 1 pending, 2 resolved, 3 expired
  created_at_millis INTEGER NOT NULL,
  expires_at_millis INTEGER,
  resolved_at_millis INTEGER,
  resolve_payload TEXT
);
