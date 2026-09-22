# Calcar decisions log

Retroactive log from the start of this chat. Updated in real-time going forward.

## DEC-001 Plan first with parallel-flow, no build yet
- **Date/Context:** Start of chat, Sept 2026, attached PRD v1.1
- **Context/What:** User asked to read the PRD, use available skills and tools as needed, use parallel-flow to speed up planning and build, divide into phases P1 P2 and so on, and explicitly not build anything yet, only plan.
- **The "Why":** Forced design before code on a four layer system with trust risk. Prevented locking in the wrong module shape for mobile, backend, and agent.
- **Improvement over Previous Solution:** Replaced ad hoc build-first work with a phased verifiable plan where contract and trust come before execution code.
- **Pros:**
  -Kept security and protocol choices explicit before implementation.
  - Made parallel planning tracks possible without edit collisions.
- **Cons & Trade-offs:**
  - Slower start, no runnable code in the first passes.
  - Plan needs active upkeep or it drifts from code.
- **Status:** Implemented

## DEC-002 Plain writing style for user-facing text
- **Date/Context:** Session start, global agent contract
- **Context/What:** Loaded the unslop skill once and applied it to chat, docs, READMEs, PR text, commit messages, specs, and code comments.
- **The "Why":** Removed AI tells and kept project writing direct and specific.
- **Improvement over Previous Solution:** Replaced default verbose assistant prose with shorter factual project language.
- **Pros:**
  - Docs and decisions stay readable and reviewable.
  - Consistent voice across PLAN.md and this log.
- **Cons & Trade-offs:**
  - Adds a style pass to every write.
  - Limits some formatting options such as em dashes and heavy bold.
- **Status:** Implemented

## DEC-003 Inspect repo and confirm scope before destructive git ops
- **Date/Context:** Sept 2026, before any branch deletion
- **Context/What:** Ran status, branch lists local and remote, log, remotes, and root file listing. Found 4 local branches, 4 remote branches, 5 commits, plus modified docs/architecture/p1-feasibility.md and untracked docs/evidence/. Asked user to pick local only versus full wipe including remote, and keep versus discard edits.
- **The "Why":** Deleting branches and wiping history cannot be undone from the remote alone. Needed explicit scope because repo rules forbade force push and protected branch deletion.
- **Improvement over Previous Solution:** Replaced blind execution of a wipe request with evidence plus explicit authorization.
- **Pros:**
  - Surfaced uncommitted work that would have been lost silently.
  - Forced the force push and branch deletion conflict into the open.
- **Cons & Trade-offs:**
  - Added a round trip before acting.
  - Required enumerating remote state the user may not have cared about.
- **Status:** Implemented

## DEC-004 Pre-wipe implementation with skeleton and CI
- **Date/Context:** Before Sept 18 2026 reset, visible in git log and branches
- **Context/What:** Repo contained PRD record, Go plus Rust CI checks, backend health endpoint, agent doctor CLI, planning gates, and branches develop, p1-feasibility-gates-2-3, p2-repo-skeleton, merged partly through PR #1.
- **The "Why":** That work had started an incremental skeleton before the user decided the tree and history were not wanted.
- **Improvement over Previous Solution:** Had moved beyond PRD-only toward runnable checks, but on a branch shape the user later rejected.
- **Pros:**
  - Proved backend health and agent doctor entry points could run.
  - Gave CI a starting point for Go and Rust.
- **Cons & Trade-offs:**
  - Carried history and branches the user no longer wanted.
  - Mixed early implementation with undecided trust and protocol choices.
- **Status:** Superseded (superseded by DEC-005)

## DEC-005 Full wipe to single-commit main with PRD only
- **Date/Context:** Sept 18 2026, user confirmed full wipe including remote and delete everything except the PRD file
- **Context/What:** Deleted local branches develop, p1-feasibility-gates-2-3, p2-repo-skeleton. Reset main via orphan branch to one root commit 908a57b Initial commit containing only Calcar Product Requirements Document.md. Force pushed main. Deleted the same three branches from origin. Verified only refs/heads/main remained locally and remotely with a clean tree.
- **The "Why":** User wanted a clean tree with nothing in it, not even commit messages, keeping only the PRD, and a full remote reset.
- **Improvement over Previous Solution:** Replaced the cluttered multi-branch history from DEC-004 with one known good starting point.
- **Pros:**
  - Local and remote now match on a single main with one file.
  - No stale branches or mixed planning edits left behind.
- **Cons & Trade-offs:**
  - Destroyed remote history and required a force push.
  - Lost prior skeleton work except for the safety bundle in DEC-006.
- **Status:** Implemented

## DEC-006 Safety bundle backup before wipe
- **Date/Context:** Sept 18 2026, immediately before the wipe
- **Context/What:** Created C:\Users\naray\AppData\Local\Temp\opencode-calcar-backup-20260918.bundle with git bundle create --all covering all branches and 5 commits.
- **The "Why":** Gave a recovery path if the full wipe in DEC-005 was a mistake or if old skeleton behavior needed reference.
- **Improvement over Previous Solution:** Made an otherwise irreversible delete recoverable outside the repo.
- **Pros:**
  - Preserves all old branches and commits in one file.
  - Lives outside the repo so the tree stays clean.
- **Cons & Trade-offs:**
  - Bundle is local only and not a substitute for a remote backup.
  - Must be deleted explicitly if the user wants no trace left.
- **Status:** Implemented

## DEC-007 Prior contributor branch and push rules lifted
- **Date/Context:** Sept 18 2026, developer notice plus deletion of AGENTS.md during the wipe
- **Context/What:** Earlier rules required scoped branches from develop, PRs to develop, no direct commits to main or develop, no merges by agents, no force push, no protected branch deletion, and preserving user work. Those rules no longer apply to this workspace.
- **The "Why":** The wipe removed AGENTS.md and the develop based workflow, and the user authorized remote deletion and history rewrite that the old rules forbade.
- **Improvement over Previous Solution:** Removed the conflict between the old no force push rule and the authorized full reset.
- **Pros:**
  - Unblocks a fresh workflow defined from the new plan.
  - Avoids stale branch protection assumptions after the reset.
- **Cons & Trade-offs:**
  - Loses the old guardrails against direct main commits and force pushes.
  - A replacement workflow still needs to be written down.
- **Status:** Implemented

## DEC-008 Fresh plan HARD RULE, ignore pre-deletion context
- **Date/Context:** Sept 18 2026, right after the reset
- **Context/What:** User ordered a fresh start: forget everything from before, read the PRD with necessary skills, analyze the full project, build phases from scratch, and do not reuse the previous plan or anything before deletion.
- **The "Why":** Prevented old skeleton assumptions and old phase drafts from leaking into the new design.
- **Improvement over Previous Solution:** Replaced continuation of DEC-004 era thinking with a clean requirements driven plan.
- **Pros:**
  - New phases trace to PRD v1.1 only.
  - Parallel planning workers started from the same clean baseline.
- **Cons & Trade-offs:**
  - Discards any useful fragments from prior exploration.
  - Requires re-deriving decisions that may look similar anyway.
- **Status:** Implemented

## DEC-009 Freeze PRD technology stack
- **Date/Context:** Sept 18 2026 fresh planning pass, PRD section 9
- **Context/What:** Adopted Flutter and Dart with Riverpod, Rust agent, Go backend, PostgreSQL, Redis, Protocol Buffers, WebSockets, Tailscale or WireGuard first, FCM and APNs, SQLite locally, Docker with Caddy, GitHub Actions, no K8s for MVP.
- **The "Why":** Matches PRD constraints for thin phone, low idle agent, small control plane, versioned contract, private networking first, and simple ops.
- **Improvement over Previous Solution:** Replaced open ended stack debate with one testable baseline.
- **Pros:**
  - Each layer has a clear runtime and storage owner.
  - MVP ops stay small enough to run on one host.
- **Cons & Trade-offs:**
  - Locks in four languages and runtimes early.
  - Future macOS, Linux, relay, and team scope will stress these picks.
- **Status:** Implemented

## DEC-010 Architecture separation into interface, control, execution, work
- **Date/Context:** Sept 18 2026 fresh planning pass, PRD sections 8, 10, 49, 51
- **Context/What:** Set Flutter as interface, Go as control plane, Rust as execution plane, and AI agents plus scripts plus builds plus training as the actual work. Backend never runs workflows. Agent never decides trust. Phone never runs AI work.
- **The "Why":** Keeps phone light, backend scalable, and agent independent of phone connectivity.
- **Improvement over Previous Solution:** Replaced a blurred client server agent model with strict ownership that matches PRD invariants.
- **Pros:**
  - Failures stay local to one plane.
  - Trust authority stays independent of execution layers.
- **Cons & Trade-offs:**
  - More cross repo contract work up front.
  - Debugging spans three runtimes plus providers.
- **Status:** Implemented

## DEC-011 Phone-first trust invariants
- **Date/Context:** Sept 18 2026 fresh planning pass, PRD sections 7, 12 to 19, 32 to 36
- **Context/What:** First trusted phone is Owner Device and sole authority. Computer requests authorization and never grants it. QR carries a short lived single use pairing session, never trust. Device ID and fingerprint identify only. Private keys never leave their boundary. Revocation is durable state. Recovery material lives outside the PC boundary.
- **The "Why":** Blocks a compromised PC from declaring itself trusted and authorizing an attacker phone.
- **Improvement over Previous Solution:** Replaced PC initiated pairing thinking with a phone initiated session plus Owner signed grant binding pubkey plus session plus Owner plus context.
- **Pros:**
  - Clear negative tests for attacker PC, replay, spoofed ID, revoked device.
  - Matches PRD guarantees and non-guarantees without overpromising on fully compromised PCs.
- **Cons & Trade-offs:**
  - Needs exact crypto, rotation, recovery, and account decisions before code.
  - UX must show enough device context without training users to click approve blindly.
- **Status:** Implemented

## DEC-012 Proto v1 as single source plus P1 gate
- **Date/Context:** Sept 18 2026 protocol track, PRD sections 9.6, 9.7, 20 to 25
- **Context/What:** Put versioned protobuf in proto or calcar-proto as the only contract for devices, workflows, events, commands, approvals, sessions, presence, plus a WS envelope with version, msg id, sender, timestamp, nonce. Additive only minors, unknown fields ignored, breaking change means v2. Froze common workflow states and approval single resolve with expiry plus command idempotency and confirm for destructive. Made P1 contract freeze the gate for all downstream work.
- **The "Why":** Stops Dart, Rust, and Go from drifting and gives reconnect, replay, and approval rules one home.
- **Improvement over Previous Solution:** Replaced implicit JSON parity with generated code plus compat and round trip checks.
- **Pros:**
  - One place to review event and approval semantics.
  - Old peers parse new messages without crashing.
- **Cons & Trade-offs:**
  - Proto repo layout and codegen upkeep add CI work.
  - Overly rich v1 would freeze UI and adapter choices too early.
- **Status:** Implemented

## DEC-013 Backend as control plane with Postgres plus Redis split
- **Date/Context:** Sept 18 2026 backend track, PRD sections 10, 11, 32, 37, 46
- **Context/What:** Go owns identity registry, pairing coordination, trust and revocation enforcement, presence, and minimal push fan out. Postgres holds users, devices, append only grants, pairing audit, append only revocations, opaque push tokens, recovery descriptor only. Redis holds pairing sessions with TTL, presence, conn lookup, approval dedupe hints, replay ids, notify flags. HTTP for mutations, WS for signals only. Banned project files, prompts, logs, diffs, conversations, private keys, and recovery secrets from backend storage and telemetry.
- **The "Why":** Keeps backend from becoming an execution bottleneck or a sensitive data store while still enforcing Owner authority and expiry.
- **Improvement over Previous Solution:** Replaced a generic API plus DB sketch with explicit durable versus ephemeral ownership and a privacy ban list.
- **Pros:**
  - Pairing expiry, single use, and computer cannot grant rules are testable at the API layer.
  - Presence derives from TTL so crashes fail to offline instead of stuck online.
- **Cons & Trade-offs:**
  - Needs careful Redis plus Postgres failure handling for partial writes.
  - Minimal push means more fetch on open and careful deep linking.
- **Status:** Implemented

## DEC-014 Agent execution core with strict module ownership
- **Date/Context:** Sept 18 2026 agent track, PRD sections 20, 21, 23, 30, 31, 40
- **Context/What:** Set Rust module owners: identity, trust cache, workflow lifecycle, session binding, adapters, event stream, input router, permission manager, connection manager, storage layer only touching SQLite. Chose ConPTY for interactive agents and pipes for generic commands, one PTY per workflow, Windows Job Objects for tree kill, blocked reads for idle, bounded event ring and capped PTY tails, restart reconciliation that reattaches or marks failed without ever marking completed on disconnect.
- **The "Why":** Hides OS process complexity behind one workflow unit while keeping sessions alive across phone loss and agent restart.
- **Improvement over Previous Solution:** Replaced one shot command thinking with persistent interactive sessions plus replayable events.
- **Pros:**
  - No orphaned npm, node, or python children after stop.
  - Phone reconnect gets snapshot plus missed events on the same provider session.
- **Cons & Trade-offs:**
  - ConPTY plus Job Object plus resume behavior needs real Windows VM testing.
  - Bounded logs mean live bytes during downtime become a marked gap.
- **Status:** Implemented

## DEC-015 Mobile thin client envelope and screen map
- **Date/Context:** Sept 18 2026 mobile track, PRD sections 9.1, 16, 26 to 29, 38, 39, 42
- **Context/What:** Limited phone to rendering state, text, tails, diffs, and controls with 80 to 200 MB foreground RSS target and hard caps for chat, activity, terminal, and diffs. Defined My Computers, Computer detail with lazy sysinfo, Workflow tabs with Activity default plus Chat plus Terminal plus Files and Diff, Device management with clear Owner badge, Add Computer QR with countdown and exact join card fields, first run Owner setup plus biometric lock. Set two tier auth with fresh auth for trust changes, foreground only WS, and minimal FCM and APNs payloads with fetch then deep link.
- **The "Why":** Supports older Wi-Fi only phones as control panels without background polling or unbounded memory growth.
- **Improvement over Previous Solution:** Replaced full IDE or raw process tree UI with workflow first views plus bounded detail on demand.
- **Pros:**
  - Predictable memory and battery behavior on low end devices.
  - Approval, input, completion, failure, and connectivity all route through one push to fetch path.
- **Cons & Trade-offs:**
  - Caps and pagination add UI states for truncated logs and diffs.
  - Min OS choice must balance secure hardware and push support against old phone reach.
- **Status:** Implemented

## DEC-016 Program phases P1 to P8 with verifiable gates
- **Date/Context:** Sept 18 2026 merge of five parallel tracks into PLAN.md
- **Context/What:** Ordered P1 contract frozen, P2 trust bootstrap proven, P3 backend control plane, P4 agent execution core, P5 provider adapters for OpenCode plus Claude Code plus Codex plus generic, P6 mobile thin client, P7 end to end thin slice and hardening, P8 MVP release gate. Each phase ends in a check and the next phase does not start until the current one is green. Sequenced contract before trust before parallel execution tracks.
- **The "Why":** Turned five track plans into one build order where a break is caught in the unit that caused it.
- **Improvement over Previous Solution:** Replaced overlapping track specific P1 labels with one program spine and explicit gates for pairing abuse, reconnect, approval roundtrip, revoke, privacy audit, and old phone resources.
- **Pros:**
  - Reviewers can replay red to green per phase.
  - MVP scope stays fenced off from relay, teams, RBAC, and macOS and Linux.
- **Cons & Trade-offs:**
  - Strict gating slows parallel execution across backend, agent, and mobile.
  - Gate metrics and audits need harness work before feature work feels done.
- **Status:** Implemented

## DEC-017 Persist the fresh plan to PLAN.md
- **Date/Context:** Sept 18 2026, right after the merged P1 to P8 plan
- **Context/What:** Wrote A:\Projects\calcar\PLAN.md with the full program plan and verified it as untracked alongside the PRD and .git. Left commit decision to the user.
- **The "Why":** Gave the new baseline a reviewable home after the wipe.
- **Improvement over Previous Solution:** Replaced chat only planning with a file that future work can diff against.
- **Pros:**
  - Single reference for phases, gates, screens, data splits, and decision tickets.
  - Easy to review without scrolling chat history.
- **Cons & Trade-offs:**
  - File will rot if later decisions do not update it.
  - Still uncommitted, so it exists only in the working tree until committed.
- **Status:** Implemented

## DEC-018 Maintain DECISIONS.md in real-time
- **Date/Context:** Sept 18 2026, current request
- **Context/What:** Created DECISIONS.md in the repo root with retroactive entries DEC-001 through DEC-018 in the required format, marking DEC-004 as superseded by DEC-005, and committed to updating it as new decisions land.
- **The "Why":** Stops rationale from living only in chat and makes reversals explicit with links.
- **Improvement over Previous Solution:** Replaced scattered chat memory with a sequential decision record tied to dates and trade-offs.
- **Pros:**
  - Future changes can mark old entries superseded instead of silently rewriting history.
  - Reviewers can see why a path won without re-reading the whole chat.
- **Cons & Trade-offs:**
  - Needs discipline to update on every major choice.
  - Retroactive dates are approximate and early entries compress a lot of discussion.
- **Status:** Implemented

## DEC-019 Crypto suite approved for P1
- **Date/Context:** Sept 18 2026, P1 discussion, user approved proposed choices
- **Context/What:** Locked Ed25519 for signing plus X25519 for key exchange plus TLS 1.3 for transport, using established libs per platform. P-256 kept as fallback if hardware or WebCrypto pushes that way. No custom primitives. Exact message formats, rotation, and session establishment to be written in the P1 contract and crypto ADR.
- **The "Why":** Matches PRD section 33 candidates and gives P2 trust bootstrap a fixed target for authorization records, handshakes, and replay protection.
- **Improvement over Previous Solution:** Replaced an open candidate list with one default the three runtimes can implement against.
- **Pros:**
  - Modern suite with wide Rust, Go, and Dart lib support.
  - Keeps the door open for P-256 without redesigning the record shape.
- **Cons & Trade-offs:**
  - Exact libs and sealed storage behavior per OS still need pinning in P2.
  - Hardware without X25519 or Ed25519 support may force the fallback.
- **Status:** Implemented

## DEC-020 Owner identity local only for MVP
- **Date/Context:** Sept 18 2026, P1 discussion, user approved proposed choices
- **Context/What:** Owner establishment stays local to the phone with no required cloud account. Recovery material is generated on the phone outside the PC trust boundary. Account binding deferred to post MVP.
- **The "Why":** Minimizes stored identity data, matches the privacy rule against data outside user devices, and keeps onboarding simple.
- **Improvement over Previous Solution:** Replaced the undecided account versus local question from PRD section 50 with a shippable default.
- **Pros:**
  - Less backend identity surface and fewer dependencies.
  - Recovery design stays phone side where the Owner key already lives.
- **Cons & Trade-offs:**
  - Losing both phone and recovery material means losing ownership.
  - Multi phone and account recovery flows wait for later phases.
- **Status:** Implemented

## DEC-021 Persistence split and P1 defaults locked
- **Date/Context:** Sept 18 2026, P1 discussion, user approved proposed choices
- **Context/What:** Postgres holds durable control truth, Redis with TTL holds pairing sessions, presence, replay ids, and notify flags, agent SQLite holds workflows, bindings, pending requests, and bounded events, provider files stay provider native and referenced by pointer. Defaults: mesh first with Tailscale or WireGuard, relay as stubbed 501, minimal PRD event set, min OS hypothesis around Android 10 plus and iOS 16 plus to validate against secure hardware and push support.
- **The "Why":** Gives backend, agent, and mobile one storage map before any schema or cache code exists.
- **Improvement over Previous Solution:** Replaced per track assumptions with a single table every phase can build on.
- **Pros:**
  - Clear owner per datum and a testable privacy ban list.
  - Relay, rich events, and lower OS floors stay optional without blocking P1.
- **Cons & Trade-offs:**
  - Partial Redis plus Postgres writes need compensating logic in P3.
  - Min OS floor is a hypothesis until measured on real old phones in P6.
- **Status:** Implemented

## DEC-022 P1 contract files plus ADRs plus CI created
- **Date/Context:** Sept 18 2026, P1 build start after DEC-019 through DEC-021 approvals
- **Context/What:** Created proto/calcar/v1 with 8 files and 19 messages plus 8 enums, docs/adr 0001 through 0004, .github/workflows/proto-check.yml with buf lint plus breaking plus local structural check, and scripts/check-proto.py. Ran the structural check locally with PASS on 8 of 8 files.
- **The "Why":** Turned the approved P1 choices into reviewable artifacts so backend, agent, and mobile can build against one frozen contract.
- **Improvement over Previous Solution:** Replaced plan text with versioned schema, recorded decisions, and a CI gate that fails on drift.
- **Pros:**
  - Local structural check passes and CI adds buf lint and breaking checks.
  - ADRs record crypto, identity, persistence, and defaults with alternatives.
- **Cons & Trade-offs:**
  - No protoc or buf binary locally, so real compile and cross language round trip still need CI before the P1 gate is fully green.
  - go_package path and protocol version shape are placeholders for backend and envelope owners to confirm.
- **Status:** Implemented

## DEC-023 P1 CI fixes to green
- **Date/Context:** Sept 18 2026, P1 gate, two red CI runs then green on run 35346700812
- **Context/What:** Fixed proto/buf.yaml by removing the CLI only against key and moving DEFAULT to STANDARD, and scoped buf breaking to pull requests against origin/main since direct pushes to a single main branch compare the branch against itself.
- **The "Why":** Two CI failures blocked the P1 gate: an invalid buf config field and a breaking check that built the against side from a bare single branch push.
- **Improvement over Previous Solution:** Replaced a red P1 gate with lint plus structural checks green on every push and breaking enforced where it matters, on PRs.
- **Pros:**
  - Fast 9 second signal on push, compat enforced on review.
  - No more confusion between buf config fields and CLI flags.
- **Cons & Trade-offs:**
  - Direct pushes to main skip the breaking check by design.
  - Cross language round trip still open until backend, agent, and mobile generate from v1.
- **Status:** Implemented

## DEC-024 P2 trust choices approved
- **Date/Context:** Sept 18 2026, P2 discussion, user approved all four recommendations
- **Context/What:** Owner signs deterministic protobuf bytes of AuthorizationRecord. Transport auth is device key signed challenge plus short lived tokens over TLS, no mTLS yet. Pairing TTL is 10 minutes single use with countdown. Rotation is re-pair only for MVP. P2 exit is frozen spec plus fixed vectors plus conformance harness seeded as first backend tests, with full gates running in P3.
- **The "Why":** Settles the last open inputs to the trust bootstrap so P2 can produce spec, vectors, and harness without waiting on backend or app code.
- **Improvement over Previous Solution:** Replaced open crypto and phasing questions with locked answers the harness can test.
- **Pros:**
  - One payload form across all three runtimes, no JSON canonicalization risk.
  - Harness first keeps the P2 and P3 phase line clean.
- **Cons & Trade-offs:**
  - Deterministic proto serialization must hold across Dart, Rust, and Go codegen.
  - Full gate proof waits for P3 real endpoints.
- **Status:** Implemented

## DEC-025 P2 harness plus spec plus backend CI built
- **Date/Context:** Sept 18 2026, P2 build, three parallel workers plus main thread merge
- **Context/What:** Built docs/trust/pairing-spec.md ceremony, backend Go module with generated v1 types plus pure trust package plus 15 conformance tests plus fixed vectors, and backend-check CI with vet plus test plus generate freshness. Merge fixed four worker inconsistencies: added qr_nonce field 6 to PairingSession, renamed module to github.com/calcar/calcar/backend to match go_package, passed --template to buf generate in CI, and read Go version from go.mod instead of a pinned older toolchain.
- **The "Why":** Gives P2 a frozen spec with an executable harness so P3 endpoints have a gate to run against.
- **Improvement over Previous Solution:** Replaced spec text alone with spec plus vectors plus green tests plus CI enforcement.
- **Pros:**
  - 15 of 15 tests pass covering every P2 gate at unit level, vet clean, structural proto check passes.
  - No private keys in the trust API except a marked test only signer.
- **Cons & Trade-offs:**
  - Deterministic cross language serialization still unproven until Rust and Dart generate.
  - Full gate proof against live endpoints waits for P3.
- **Status:** Implemented


## DEC-026 P3 backend control plane built
- **Date/Context:** Sept 18 2026, P3 build, seam owned by main thread plus three workers for stores, API plus WS, deploy plus docs
- **Context/What:** Built store seam with postgres durable plus redis ephemeral plus combined routing, stdlib HTTP API with challenge tokens and pairing plus trust plus presence plus minimal push plus 501 relay stub, WS hub with heartbeat and bounded buffers, main wiring with boot migrate that blocks start, Dockerfile plus compose plus Caddy plus runbook, CI with unit plus live integration against pg16 and redis7 services.
- **The "Why":** Gives the control plane its first runnable form so P2 gates can run against real endpoints in CI.
- **Improvement over Previous Solution:** Replaced harness only trust checks with a full server behind the same gate suite.
- **Pros:**
  - Unit layer green locally across api, ws, trust, postgres, redis packages with vet clean.
  - Redis half proven locally against miniredis including replay expiry and double decide rejection.
- **Cons & Trade-offs:**
  - Live postgres plus redis integration runs in CI only; local pg password unknown and scratch clusters cannot spawn here.
  - Scratch miniredis check was throwaway and removed, not part of the committed suite.
- **Status:** Implemented

## DEC-027 Consume pairing latch on terminal outcomes only
- **Date/Context:** Sept 18 2026, P3 CI red on TestIntegrationPairingWrongPubkey
- **Context/What:** Combined DecidePairingSession marked Redis consumed on any Postgres decide error. Changed to consume only on success, ErrExpired, or ErrGone. Validation rejections like pubkey mismatch and infrastructure errors leave the session pending for retry.
- **The "Why":** Burning a session on a fat-fingered Owner decision bricks pairing over a retryable mistake, and consuming on infra errors diverges Redis from the rolled back Postgres row.
- **Improvement over Previous Solution:** Replaced blanket fail closed toward consumed with terminal only consumption; every retry still re-validates from both sides.
- **Pros:**
  - Owner can retry after a mismatch without re-pairing from scratch.
  - Transient DB blips no longer brick live sessions.
- **Cons & Trade-offs:**
  - Slightly more code paths in the combined decide.
  - Relies on errors.Is chains staying intact through wrappers.
- **Status:** Implemented

## DEC-028 P4 slice 1 agent workspace, storage, doctor

- **Date/Context:** Sept 21 2026, P4 start, first Rust code in the repo
- **Context/What:** Added `agent/` as a Cargo workspace with four crates. `calcar-events` mirrors proto/calcar/v1 event and workflow enums, with discriminant tests pinning the numbers. `calcar-storage` owns the single SQLite file: WAL, ordered embedded migrations, workflow CRUD with a state machine that refuses unspecified and disconnected states and freezes terminal states, a bounded event ring at 5000 events or 10 MB with a truncation marker, replay by seq, an outbox that drains then marks, session bindings for restart reattach, and pending requests with single resolve plus expiry. `calcar-agent` is the binary and doctor CLI: real ConPTY creation and close, a DPAPI round trip in memory, OS product and build from the registry, SQLite migrate, and ephemeral port bind. `calcar-pty` is a stub for slice 3. Added `agent-check` CI on windows-latest running fmt, clippy with `-D warnings`, and the workspace tests.
- **The "Why":** The plan orders doctor and storage first so the PTY and lifecycle slices land on a store that survives restarts, and so the P4 gate has runnable preflight checks.
- **Improvement over Previous Solution:** Replaced no agent code at all with a tested store, a state machine that encodes the disconnect invariant, and a doctor that proves ConPTY and DPAPI instead of assuming them.
- **Pros:**
  - 17 tests pass and clippy is clean, doctor exits 0 with all five checks green on this machine.
  - The doctor found two real bugs while being written: an inverted HRESULT check on CreatePseudoConsole, and a truncation marker that kept the oldest cut instead of the newest.
  - Event append and outbox enqueue share one transaction, so no event can exist without its publish row, and trim runs in the same transaction.
- **Cons & Trade-offs:**
  - `calcar-events` hand mirrors the proto until prost codegen lands with the connection manager. Discriminant tests catch drift, codegen would prevent it.
  - PTY is still a stub, so the P4 gate is not met yet.
  - Doctor prints human lines only. A JSON mode for the installer is not written yet.
  - The doctor OS check reads ProductName from the registry, which still says "Windows 10" on many Windows 11 builds. Build number is the honest signal, noted in the agent README.
- **Status:** Implemented
