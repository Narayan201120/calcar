-- 0001_init: users and device registry.
-- Devices hold public keys plus fingerprints only. Private keys are never
-- stored here (pairing spec I5).

-- +migrate Up
CREATE TABLE IF NOT EXISTS users (
  id         TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('owner_phone', 'trusted_phone', 'computer')),
  display_name  TEXT NOT NULL DEFAULT '',
  pubkey        BYTEA NOT NULL,
  fingerprint   TEXT NOT NULL DEFAULT '',
  authorized_by TEXT NOT NULL DEFAULT '',
  revoked       BOOLEAN NOT NULL DEFAULT FALSE,
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, pubkey)
);

CREATE INDEX IF NOT EXISTS idx_devices_user ON devices (user_id);

-- +migrate Down
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS users;
