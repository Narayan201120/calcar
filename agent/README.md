# Calcar agent

Runs workflows on the managed Windows computer. PLAN P4 through P7.

## Layout

| Crate | Owns |
|---|---|
| calcar-events | Common event and workflow model, mirrored from proto/calcar/v1 |
| calcar-storage | The only module that touches the SQLite file |
| calcar-pty | ConPTY sessions and job objects, one per workflow |
| calcar-agent | The binary and the doctor CLI |

Storage holds Calcar state only: workflows, the bounded event ring, outbox
cursors, session bindings, and pending requests. Provider transcripts and
project files stay with the provider. PRD 24.

## Doctor

```powershell
cargo run -p calcar-agent -- doctor
```

Five checks: OS version from the registry, ConPTY creation and close, a DPAPI
round trip in memory, SQLite migrate, and an ephemeral port bind. Exit code is
non-zero when any check fails. The P4 gate wants this green on a clean Win10 and
Win11 machine.

Note: the registry ProductName value still says "Windows 10" on many Windows 11
builds. Trust the build number, not that string.

## Tests

```powershell
cargo test --workspace
```

CI runs `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D
warnings`, and the test suite on windows-latest, because ConPTY, DPAPI, and job
objects are Windows only.
