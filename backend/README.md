# calcar-api backend runbook

`calcar-api` is the P3 control-plane broker: identity, pairing, trust,
presence, push fan-out. No workflow bodies touch the backend.

## Prerequisites

- Go 1.27+ (`go version`)
- Docker Desktop (for compose: Postgres 16, Redis 7, Caddy)
- Ports free: 8080 (api), 5432 (postgres), 6379 (redis), 80/443 (caddy)

## Environment variables

| Name                | Required | Default (compose)                                              | Purpose                                  |
|---------------------|----------|----------------------------------------------------------------|------------------------------------------|
| `PORT`              | no       | `8080`                                                         | HTTP listen port                         |
| `PG_DSN`            | yes      | `postgres://calcar:<pw>@postgres:5432/calcar?sslmode=disable`  | Postgres connection URL (durable truth)  |
| `REDIS_ADDR`        | yes      | `redis:6379`                                                   | Redis host:port (ephemeral, TTL state)   |
| `POSTGRES_PASSWORD` | compose  | `calcar-dev-only-change-me` (DEV-ONLY)                         | Postgres password; set a real value outside local dev |

No secrets are committed. The compose default password is dev-only and must
be overridden via `POSTGRES_PASSWORD` in any shared or production setup.

## Run locally (no Docker)

From this directory (`backend/`):

```sh
go run ./cmd/calcar-api
```

with `PG_DSN` and `REDIS_ADDR` exported (see table). `PORT` is optional.

## Migrate behavior on boot

`Migrate` runs before the server starts listening. A migration failure
blocks startup: the process exits non-zero and serves nothing. Fix the DB
state (or the migration), then restart. Migrations must stay backward
compatible with the currently deployed API.

## Run with compose (recommended)

From the repo root:

```sh
docker compose up --build
```

This starts `api` + `postgres:16` + `redis:7` + `caddy:2`. The api waits
for `postgres` and `redis` to report healthy (`depends_on` + `pg_isready`
/ `redis-cli ping`) before starting, then runs migrations, then serves.

Stop with `docker compose down`. Data persists in the `pgdata` and
`redisdata` named volumes.

## Health endpoints

| Endpoint   | Deps checked | Use                              |
|------------|--------------|----------------------------------|
| `/healthz` | none         | liveness (Docker, Caddy, edge)   |
| `/readyz`  | Postgres + Redis (`Ping`) | readiness; fails until both backends answer |

```sh
curl localhost:8080/healthz
curl localhost:8080/readyz
```

## Structured logging

One JSON object per line. Standard fields on every request log:

`ts`, `level`, `msg`, `method`, `path`, `status`, `latency_ms`,
plus correlation ids where applicable: `req_id`, `device_id`, `session_id`.

Outcome codes reuse the stable `trust` package codes (`PAIRING_EXPIRED`,
`PAIRING_CONSUMED`, `PUBKEY_MISMATCH`, `NOT_OWNER`, `REPLAYED_ID`,
`REVOKED`, ...), so logs grep the same way as API errors.

### Privacy ban list

Never log, and never put in metric labels, traces, or error strings:

- access tokens, auth challenges, any bearer credential
- private keys, key bytes, signatures (public-key fingerprints only where
  the pairing ceremony needs them for display)
- workflow bodies: source code, prompts, terminal output, diffs, chat content
- push payload details (ids and kind only, full detail over the auth channel)

## Metrics

Deferred. Planned counters/gauges (not yet emitted): HTTP request
counts/latency, WS connection gauge, pairing outcomes, revoked-token
rejects, push fan-out counts, DB operation latency. Wire them with
OpenTelemetry when the API surface freezes.
