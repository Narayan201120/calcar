# Calcar build plan

This is the current plan. It replaces anything from before the repo reset.

## Starting point

Repo holds the PRD only. One Owner phone is the authority. One Windows PC does the work. Go backend only coordinates. Rust agent only executes. Flutter phone only renders. A shared proto contract binds them.

Sharp terms used here:

- Owner Device: first trusted phone, sole signer of trust grants, holds Owner key in hardware.
- Trusted phone: own keypair, authorized by Owner, never Owner by default.
- Managed computer: own keypair, requests trust, never grants it.
- Device ID and fingerprint: display and routing only, never proof.
- Pairing session: short lived single use phone created context with TTL. Trust is the durable Owner signed record. QR carries session only.
- Revocation: durable state, checked on every auth, propagated on reconnect.
- Recovery credential: generated outside the PC boundary, re-establishes Owner after loss.

Permanent invariants:

- PC never authorizes a phone, itself, or another PC.
- QR never equals trust.
- Sessions expire and cannot be reused.
- Auth binds exact pubkey plus session plus Owner plus context.
- Private keys stay in their boundary.
- Phone disconnect never ends a workflow.
- Provider quirks stay inside adapters.

## Proposed repo shape

```text
proto/
backend/
agent/
mobile/
docs/
  adr/
.github/workflows/
docker-compose.yml
PLAN.md
```

Proto owns the contract. No hand copied types. CI fails if generated Dart, Rust, Go drift.

## P1 Contract and decisions frozen

Goal: stop interface churn before anyone builds on it.

Work:

- Create calcar-proto v1. Devices, workflows, events, commands, approvals, sessions, connection presence. WS envelope with protocol version, msg id, sender, timestamp, nonce. Additive only minor changes. Unknown fields ignored. Breaking change means v2.
- Common event set: started, command started and completed, file changed, approval required, input required, error, completed, stopped. Approval lifecycle pending to approved, rejected, expired, superseded. Single resolve wins. Command carries idempotency key. Destructive needs second confirm.
- Record open decisions as tickets: crypto suite final, mesh versus relay, account versus local Owner, recovery design, adapter API freeze, persistence split, min OS versions. Decide crypto, Owner identity, and persistence split here. The rest can stay as bounded options with a default.
- Skeleton CI: lint, vet, proto round trip and compat check, golden proto file.

Gate: proto v1 tagged, cross language round trip green, old client parses new messages without crash. Nothing downstream starts until this is green.

## P2 Trust bootstrap proven

Goal: prove the phone is the authority before any workflow code exists.

Work:

- Owner establishment on phone with hardware key storage. Android Keystore with StrongBox or TEE fallback policy. iOS Keychain with Secure Enclave where present. Normal open uses biometric. Trust changes need fresh auth at signing time.
- Phone created pairing session with TTL around 5 to 10 minutes, single use. QR shows session reference only. PC generates its own keypair locally, seals with DPAPI plus TPM where present, submits join with pubkey, fingerprint, name, request id.
- Owner approve or reject card shows exact fields: name, Device ID, fingerprint, request time. Approve writes signed authorization binding pubkey plus session plus Owner plus context. Reject or expiry consumes session with no trust.
- Replay defence: unique request ids, timestamps, expiry, seen id cache in Redis and agent, expired or resolved approvals reject.
- Revocation record shape and enforcement points defined, even if propagation UI comes later.

Gate, all must pass:

- Attacker PC cannot authorize attacker phone without Owner tap.
- Expired session join fails. Double approve fails. Swapped pubkey fails.
- Device ID spoof with no private key authenticates nothing.
- Owner private key never appears on PC or backend in usable form.

## P3 Backend control plane

Goal: honest broker for identity, pairing, trust, presence, push fan out.

Stack: Go, Postgres for durable truth, Redis for ephemeral, Caddy for TLS, Docker Compose for deploy. No K8s. No workflow bodies on backend.

Postgres holds users, devices with role owner phone, trusted phone, computer, trust grants append only, pairing audit, revocations append only, opaque push tokens, recovery descriptor only. Redis holds pairing session with TTL, presence with TTL, conn lookup, approval dedupe hint, replay ids, minimal notify flags.

API split:

- HTTP for state changes: bootstrap Owner, device registry, pairing create, join request, decision, trust graph, revoke, presence heartbeat, attention post, push token. Mutations need auth plus revocation check plus idempotency key.
- WS at /v1/ws for signals only: join requested, decided, attention pending, presence changed, trust revoked. No state mutation over WS except subscribe and heartbeat.

Pairing role from backend view: create session, validate live pending unused session on join, emit event to Owner, verify approver is active Owner and subject pubkey matches join exactly, flip to consumed, write device plus grant.

Ops: /healthz liveness with no deps, /readyz with Postgres plus Redis checks, JSON structured logs with req id, device id, session id and no secrets, OpenTelemetry traces and counters for requests, WS gauge, pairing outcomes, revoked rejects, push fan out, DB latency. GitHub Actions runs lint, unit, migration check on ephemeral Postgres, compose smoke including pairing expiry test, then build and deploy. Migrations run before API start and block deploy on failure.

Privacy: push body carries ids and kind only. Full detail fetched over auth channel. Ban source, prompts, terminal, diffs, chat content from logs, metrics labels, traces, error strings.

Gate: happy path create to join to approve green, expired to 410, double approve to 410, wrong pubkey rejected, computer caller to grant or revoke gets 403, revoked device gets 401 or 403 on next call and WS refused, presence offline arrives within TTL window, replayed request id rejected.

## P4 Agent execution core

Goal: durable workflow unit that survives phone loss.

Layout: single calcar-agent binary plus lib, one module per owner. Storage layer alone touches SQLite. Adapters alone know providers. Connection manager alone opens sockets. Workflow manager alone writes workflow state.

Workflow is the user unit hiding N OS processes. States running, waiting input, waiting approval, completed, failed, stopped, plus disconnected but running as a projection not stored state. No transition to completed on disconnect.

PTY path: adapter to PTY manager to ConPTY child, stdout and stderr pumped on bounded channels to adapter parse to event stream, input routed back to PTY stdin. One PTY per workflow. Plain pipes for non interactive generic commands. Each workflow gets a Windows Job Object, kill ends the whole tree. Idle means blocked reads, no polling.

Storage: one SQLite file in WAL mode, sole writer is storage layer. Calcar owns workflows, session bindings, pending requests, bounded event ring around 5k events or 10 MB per workflow with truncated marker, outbox cursors. Provider owns transcripts and project files, agent stores pointers only. Raw PTY tail lives in capped rotating files, DB references path.

Order inside P4:

- Doctor CLI: OS version, ConPTY, DPAPI round trip, DB migrate, bind check.
- Storage migrations plus trim and replay tests.
- PTY echo and stdin round trip plus job kill test with parent to child to grandchild asserting none survive.
- Workflow plus session lifecycle plus restart recovery test: kill agent mid run, reboot, assert reattach or clean failed with reason.
- Event stream seq and replay plus input router idempotency with duplicate UUID dropped.

Gate: doctor passes on clean Win10 and 11 VM, PTY tests green, restart recovery green, 60 second network drop mid run keeps workflow alive with no dup or loss on reconnect.

## P5 Provider adapters

Goal: three agents behind one frozen trait, plus generic commands.

Trait: capabilities flags for streaming, interactive input, approvals, file events, resume, stop, diagnostics. Spawn, inject, respond approval, stop, parse bytes to common events, snapshot. Core only sees common events.

Adapters: opencode, claude-code, codex, generic-command for scripts, builds, training, Docker with no approvals. No provider string outside adapters folder. New provider is one new file plus registration, no mobile or backend change.

Permission manager owns approval lifecycle with expiry timers, single use, binding to workflow plus request plus device.

Gate per adapter: scripted PTY fixture passes for spawn, prompt inject, approval capture, resume token, kill semantics. Double accept rejected. Expired rejected.

## P6 Mobile thin client

Goal: old phone usable as control panel.

Boundary: render only. No AI run, no provider logic. Foreground WS only. Background is push only. Wi-Fi sufficient. No SIM, BT, NFC, GPS needed. Camera only matters because PC scans the phone QR.

Resource envelope 80 to 200 MB foreground RSS normal use. Enforced with hard caps: chat last 300 with paging, activity ring 500 with important pins, terminal tail 2000 lines or 256 KB, diff first 50 files and 200 KB total with truncated notice. ListView builder everywhere. Dispose WS on navigate away. SQLite cache with trim on foreground only.

Screens:

- My Computers: name, online state, active workflow rows with status chips. Pull refresh is one snapshot fetch. Empty state points to Add Computer.
- Computer detail: workflows primary, sysinfo CPU RAM GPU disk secondary collapsed and fetched lazily.
- Workflow with Activity default, then Chat, Terminal, Files and Diff. Approval cards show countdown and go inert after expiry or resolve. Chat has optimistic send plus retry, destructive needs confirm sheet. Terminal is paged tail. Files is capped hunks.
- Device management: trusted phones and managed computers with name, ID, type, state, last seen. Owner badged. Revoke needs fresh re-auth with optimistic removal plus rollback.
- Add Computer: create session to QR with countdown to waiting to join card to approving or rejecting to expired with regenerate. No reuse after use.
- First run: Owner establish to biometric lock to empty list. Cold start shows SQLite cache instantly then refreshes.

Realtime: WS mounted only while viewing. Snapshot then deltas into Riverpod plus SQLite. Drop shows disconnected banner and freezes state, backoff only while still mounted. Push is FCM plus APNs with minimal payload of ids and kind. Tap fetches full detail then deep links to computer, workflow, approval.

Gate: golden tests for lock, lists, QR states, card, tabs, truncated states. State tests for expiry single use, expired approval not resendable, destructive needs confirm, dispose closes socket, disconnect never marks completed. Secure storage test proves no private bytes in prefs or SQLite and cancelled auth sends nothing. Buffer tests feed 100k lines and 5 MB diff and prove caps hold.

Min OS input: pick lowest version that still gives hardware backed keys, current push, Flutter stable, TLS 1.2 plus modern suites. Validate on a 3 to 4 GB Android and older iPhone. Raise floor only if secure hardware or push missing.

## P7 End to end thin slice and hardening

Goal: one provider path proved on real hardware with abuse cases covered.

Slice: one PC, one provider plus generic, over Tailscale or WireGuard, no public SSH. View to command to approval roundtrip to disconnect to reconnect resume.

Suites:

- Reconnect reliability: kill app, drop net, restart agent, assert same provider session resumes with missed events replayed.
- Command delivery: sent to acked to applied, confirm rate tracked.
- Approval delivery: created to push to fetched to resolved with latency split, duplicate resolve rejected, expired before resolve counted.
- Security: illicit auth attempts must stay zero, revoked rejected 100 percent, replay rejected, unknown rejected.
- Privacy audit: grep logs, traces, metrics, push payloads for source, prompts, terminal, keys. Any hit fails the phase.
- Resource: release mode RSS idle and scrolling and 5 min terminal stream, cold start to cached list, 10 WS churns with no leak, battery drain, SQLite size before and after trim, approval push to rendered median and p95.

Gate: full acceptance spine green from install to revoke, plus old Wi-Fi only phone inside the RSS cap.

## P8 MVP release gate

Goal: shippable control plane plus execution plane plus thin client.

Includes Docker Compose with API plus Postgres plus Redis, Caddy TLS, health checks wired, metrics runbook, pairing plus reconnect plus approval plus command SLOs recorded, zero illicit auths, privacy audit clean, revocation propagation proved when online and on reconnect when offline.

Explicitly out for MVP: macOS and Linux agents, relay beyond a stub 501 with stable schema, team sharing and RBAC, rich Git and templates and analytics. Those follow only after the gate above stays green.

## Decision tickets to open first

- Crypto suite and libs per platform, message formats, rotation, session establishment.
- Owner identity: local only versus account binding, and what that means for recovery anchor.
- Recovery generation, storage, rotation, replacement, all outside PC boundary.
- Mesh only MVP versus limited relay, plus what relay is allowed to see for E2E.
- Adapter event freeze: minimal PRD list versus richer file and terminal streaming.
- Persistence split: what lives in Postgres versus Redis versus agent SQLite versus provider native.
- Min OS versions tied to hardware key and push support versus old phone reach.

## Done means

A new user installs, establishes Owner, adds one Windows PC over QR, sees workflows, sends an instruction, answers an approval from push, survives disconnect and reconnects to the same session, revokes a device and sees it blocked, all within resource targets, with no source or prompts in backend telemetry, and with attacker PC plus replay plus revoked device suites green.
