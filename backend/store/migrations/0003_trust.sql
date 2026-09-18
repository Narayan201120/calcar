-- 0003_trust: append-only trust grants and revocations.
-- Rows here are never updated or deleted, only superseded by revocation.
-- Enforcement reads this state on every auth (pairing spec section 10).

-- +migrate Up
CREATE TABLE IF NOT EXISTS trust_grants (
  id                BIGSERIAL PRIMARY KEY,
  subject_device_id TEXT NOT NULL DEFAULT '',
  granter_device_id TEXT NOT NULL,
  payload_hash      BYTEA NOT NULL,
  signature         BYTEA NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_grants_subject ON trust_grants (subject_device_id);

CREATE TABLE IF NOT EXISTS revocations (
  id                BIGSERIAL PRIMARY KEY,
  subject_device_id TEXT NOT NULL,
  revoker_device_id TEXT NOT NULL,
  reason            TEXT NOT NULL DEFAULT '',
  revoked_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_revocations_subject ON revocations (subject_device_id);

-- +migrate Down
DROP TABLE IF EXISTS revocations;
DROP TABLE IF EXISTS trust_grants;
