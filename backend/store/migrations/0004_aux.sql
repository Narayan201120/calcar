-- 0004_aux: connection audit, durable push token backup, recovery descriptor.
-- recovery_config holds a descriptor only (e.g. an opaque recovery anchor
-- reference). No secrets, no key material, ever.

-- +migrate Up
CREATE TABLE IF NOT EXISTS connection_metadata (
  conn_id         TEXT PRIMARY KEY,
  device_id       TEXT NOT NULL,
  user_id         TEXT NOT NULL DEFAULT '',
  connected_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  disconnected_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_connmeta_device ON connection_metadata (device_id);

CREATE TABLE IF NOT EXISTS push_tokens (
  device_id  TEXT NOT NULL,
  platform   TEXT NOT NULL,
  token      TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, platform)
);

CREATE TABLE IF NOT EXISTS recovery_config (
  user_id    TEXT PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  descriptor TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +migrate Down
DROP TABLE IF EXISTS recovery_config;
DROP TABLE IF EXISTS push_tokens;
DROP TABLE IF EXISTS connection_metadata;
