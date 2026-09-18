-- 0002_pairing: pairing session audit rows.
-- Live single-use enforcement lives in Redis with TTL; this table is the
-- durable backup. Terminal states (approved, rejected, expired) latch into
-- consumed semantics: a session id is usable at most once.

-- +migrate Up
CREATE TABLE IF NOT EXISTS pairing_sessions (
  id                TEXT PRIMARY KEY,
  user_id           TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_by        TEXT NOT NULL DEFAULT '',
  status            TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'consumed')),
  expires_at        TIMESTAMPTZ NOT NULL,
  qr_nonce          TEXT NOT NULL DEFAULT '',
  join_pubkey       BYTEA,
  join_fingerprint  TEXT NOT NULL DEFAULT '',
  join_name         TEXT NOT NULL DEFAULT '',
  join_request_id   TEXT UNIQUE,
  decided_at        TIMESTAMPTZ,
  granter_device_id TEXT NOT NULL DEFAULT '',
  granter_signature BYTEA,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pairing_user ON pairing_sessions (user_id);

-- +migrate Down
DROP TABLE IF EXISTS pairing_sessions;
