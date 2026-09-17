## Scope

P2 repository skeleton. Establishes the verified foundations each worker can
build on, plus the planning gates that keep P1 honest:

- `backend/`: Go 1.27 stdlib HTTP API foundation. `GET /healthz` returns 200;
  `GET /readyz` returns 503 `not_configured` until backing services exist.
  Graceful shutdown on SIGINT/SIGTERM with a 10 s drain.
- `agent/`: dependency-free Rust workspace. `calcar-agent --version` and
  `calcar-agent doctor`, which reports platform info and explicitly lists
  identity, network, and workflow runtime as unimplemented. No listeners,
  process management, credentials, or remote control.
- `docs/architecture/p1-feasibility.md`: the five P1 decision gates with
  owners, required evidence, pass criteria, and available/missing tools.
  All gates are open; nothing has been tested.
- `AGENTS.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.gitignore`, `README.md`:
  contributor rules, review checklist, ignores, and honest status.

This is scaffolding only. It does not satisfy any P1 gate and implements no
trust, pairing, workflow, or provider behavior.

## Verification

- `backend`: `go test ./...` (6 tests incl. live-listener shutdown), `go vet`
  clean. Live run: `/healthz` 200, `/readyz` 503, `POST /healthz` 405,
  `GET /nope` 404 (verified by the subagent that wrote it; test suite rerun
  locally after the module path change).
- `agent`: `cargo fmt --all --check`, `cargo clippy --workspace
  --all-targets -- -D warnings`, `cargo test --workspace` (7 tests). CLI
  integration tests spawn the real binary. `calcar-agent doctor` exercised:
  reports windows / x86_64 and all three subsystems not implemented.
- Module path corrected to `github.com/Narayan201120/calcar/backend`; tests
  rerun after the rename.

## Limitations and dependencies

- Flutter and Buf are not installed on this machine, so mobile scaffolding and
  protocol generation are absent. Do not treat missing folders as components.
- GitHub branch protection and CI workflows are not configured; local branch
  names provide no enforcement.
- P1 gates (docs/architecture/p1-feasibility.md) are all open; P2 contracts
  inherit that uncertainty.
- No database, auth, pairing, workflows, providers, UI, or deployment config.

## Review

- [x] Target branch is `develop`.
- [x] No credentials or sensitive workflow content included.
- [x] Relevant checks passed and evidence is attached.
- [x] Known limitations stated.
- [x] Auto-merge disabled. The user decides whether to merge.
