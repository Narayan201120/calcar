# ADR 0003: Persistence Split

## Status

Accepted (P1). Implements DEC-021 (storage half). Answers the PRD section 50 workflow-persistence question at the ownership level; exact schemas land in P3 (backend) and P4 (agent).

## Context

PRD sections 9.4, 9.5, 9.10, 10, 11, 23, 30, and 37 split durable control truth (backend), short-lived coordination state (cache), and execution state (agent), while requiring that workflow output, project information, file changes, conversations, and terminal data stay on the computer unless a cloud feature explicitly requires otherwise, and that telemetry never collects source, terminal history, or conversations. PLAN.md P1 must fix who owns what before any schema or cache code exists, or each track invents its own copy.

## Decision

Ownership map:

| Datum | Owner | Store | Notes |
|---|---|---|---|
| Users, Owner id + Owner public key | Backend | Postgres (durable) | No passwords for MVP (local-only Owner, ADR 0002) |
| Devices (Owner phone, trusted phones, managed computers): id, type, name, public key, fingerprint, authorizing authority, state | Backend | Postgres (durable) | Device ID is routing/display only, never proof |
| Trust grants (Owner-signed: subject pubkey + session + Owner + context) | Backend | Postgres, append-only | Checked on every auth |
| Revocations | Backend | Postgres, append-only | Checked on every auth; propagate on reconnect |
| Pairing audit (created/consumed/expired/rejected) | Backend | Postgres (durable) | Complements ephemeral session below |
| Opaque push tokens | Backend | Postgres (durable) | Token only; no message bodies |
| Recovery descriptor (pointer/metadata) | Backend | Postgres (durable) | Never the secret itself |
| Pairing sessions (pending, single-use) | Backend | Redis with TTL (~5-10 min) | Expired/double-use join fails |
| Presence, connection lookup | Backend | Redis with TTL | Crashes decay to offline, never stuck online |
| Approval dedupe hints, replay/seen ids, minimal notify flags | Backend | Redis with TTL | Expired/resolved approvals reject reuse |
| Workflows, lifecycle state | Agent | Agent SQLite (WAL, sole writer = storage layer) | Running, waiting-input, waiting-approval, completed, failed, stopped; disconnected-running is a projection, never stored |
| Session bindings (workflow to provider session/resume token) | Agent | Agent SQLite | Survives phone loss and agent restart |
| Pending approval/input requests with expiry | Agent | Agent SQLite | Single-resolve, bound to workflow + request + device |
| Bounded event ring (~5k events or ~10 MB per workflow, truncated marker) | Agent | Agent SQLite | Replay missed events on reconnect |
| Raw PTY tail (capped rotating files, DB holds path pointer) | Agent | Local files + SQLite pointer | Never unbounded in DB |
| Outbox cursors, trim state | Agent | Agent SQLite | At-least-once event delivery bookkeeping |
| Transcripts, project files, full logs, provider-native session data | Provider-native | Provider files on PC, referenced by pointer | Agent stores pointers only; Calcar never re-owns provider state |
| Cached workflow state, local app data (trimmed on foreground) | Mobile | Mobile SQLite or equivalent | Cache only; server/agent is truth on refresh |

Privacy ban list (backend storage AND all telemetry: logs, metrics labels, traces, error strings, push payloads):

- No source code, prompts, terminal output/history, diffs/file contents, AI conversations/chat content, private keys, or recovery secrets on the backend or in telemetry.
- Push payloads carry ids + kind only; full detail is fetched over the authenticated channel.
- Structured backend logs carry request id, device id, session id; never secrets or content.

## Alternatives considered

- Backend-owned event/log mirror for easier phone fetch: rejected for MVP. Turns the backend into an execution data store, breaks PRD section 37, and grows breach surface. Phones fetch detail from the agent path instead.
- Redis persistence (AOF) as substitute for Postgres on grants/revocation: rejected. Ephemeral store must never be the authority for trust; TTL loss must degrade to safe rejection, not silent trust loss.
- Provider transcripts inside Calcar SQLite for unified replay: rejected. Duplicates provider-native state, balloons the DB, and conflicts with the bounded-ring rule. Pointers only.

## Consequences

- P3 defines Postgres tables, Redis key shapes/TTLs, and the partial-write rule (Redis+Postgres failure handling must fail closed: no trust granted on ambiguous writes).
- P4 defines SQLite migrations, trim/replay behavior, PTY tail file caps, and restart reconciliation (reattach or clean-failed, never mark completed on disconnect).
- P6 mobile cache follows the same ban list: no private key bytes in prefs or SQLite (tested).
- P7 privacy audit greps logs, traces, metrics, and push payloads for banned classes; any hit fails the phase.
- Open: exact TTL values, ring byte/event caps tuning, and push-token rotation policy. All set in P3/P4/P6 implementation, not here.
