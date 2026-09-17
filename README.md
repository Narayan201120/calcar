# Calcar

Calcar is a planned phone interface for monitoring and controlling development
workflows on a user's Windows computer. The phone authorizes devices; execution
stays on the computer.

## Current status

This repository contains an early foundation, not a working remote-control app.
Pairing, authentication, networking in the Agent, workflow execution, provider
adapters, mobile UI, and notifications are not implemented. P1 feasibility
checks remain open in [the decision checklist](docs/architecture/p1-feasibility.md).
The product requirements are in [the PRD](Calcar%20Product%20Requirements%20Document.md).

## Layout

- `backend/`: Go HTTP health-check foundation.
- `agent/`: dependency-free Rust workspace with a diagnostic CLI.
- `docs/architecture/`: unresolved feasibility gates and evidence requirements.

Mobile, protocol generation, and deployment configuration will be added after
prerequisites and contracts are settled. Do not treat absent folders as
implemented components.

## Local checks

From `agent/`:

```text
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p agent-cli -- doctor
```

The doctor command reports build-platform information and explicitly lists
unimplemented subsystems. It does not claim the computer is ready for Calcar.

From `backend/`:

```text
go test ./...
```

Flutter and Buf were not available on PATH during initial setup. Their absence
blocks mobile scaffolding and protocol generation, not the Rust checks above.

## Contribution workflow

Working branches open pull requests into `develop`. Releases open pull requests
from `develop` into `main`. Agents never merge or enable auto-merge.

The [GitHub repository](https://github.com/Narayan201120/calcar) has `main` and
`develop`, both bootstrapped with the PRD only. Implementation belongs on
`p2-repo-skeleton` and later working branches. Branch protection and required
CI checks are not configured yet. Local branch names alone do not protect a
branch.

No license has been selected. No provider credentials are needed for this
foundation.
