# P1 feasibility gates: decision checklist

Status: planning scaffold only. Nothing below has been tested. Every gate is
open. The defaults come from the build plan (section 2) and the PRD; they are
proposals, not validated decisions. This file must not be read as evidence
that P1 passed.

Each gate lists: the decision, the owner, evidence required, pass criteria,
what hardware/tools are available vs missing, and the proposed default.

Owners are role names from the plan's worker scopes (section 5). No owner has
confirmed assignment yet.

---

## Gate 1: Native mobile hardware-backed P-256 signing

Proposed default (untested): owner keys live in Secure Enclave (iOS) or
Android hardware-backed Keystore, generating non-exportable P-256 keys;
signing happens inside the secure boundary. StrongBox is optional, not a
requirement for every supported phone.

- Owner: contracts/security.
- Evidence needed: on physical Android and iOS devices, create a key, sign a
  fixed test payload, verify the signature in Go and Rust, confirm the key
  cannot be exported, and record OS versions and available hardware protection.
  Also confirm Flutter access to native signing APIs. Use platform-specific
  evidence; do not assume Android-style key attestation exists on iOS.
- Pass criteria: signature verifies cross-language; native signing does not
  export private keys; hardware backing evidence and limitations documented
  per platform and device.
- Available: none. No physical Android or iOS device has been used for this.
  No attestation report captured.
- Missing: physical devices (both platforms), a Mac for iOS work, and a
  verification harness in Go/Rust.
- If it fails: stop and decide whether to exclude unsupported devices or
  revise the security policy. Do not silently fall back to software keys.

## Gate 2: Per-user Windows session host lifetime

Proposed default (untested): the agent runs per Windows user (not
LocalSystem); each workflow gets its own session host process; a crashed
session host ends the workflow except where the provider supports resumption.

- Owner: Windows runtime.
- Evidence needed: measure real behavior on a Windows machine: start a
  session host as a normal user, kill it, restart it, log out/log in, sleep/
  resume, and observe what survives. Test ConPTY lifetime against the host
  process. Determine whether provider sessions survive host restarts.
- Pass criteria: documented lifetime table per failure mode (crash, logout,
  sleep, reboot); explicit statement of what a reconnect can and cannot
  restore; no claim of PTY recreation without provider support.
- Available: a Windows dev machine exists but no lifecycle tests have run.
- Missing: test matrix execution, sleep/restart fixtures, provider resumption
  facts.
- If it fails: the persistence guarantees in the plan (section 2, item 6) need
  rewriting before contracts are frozen.

## Gate 3: Structured OpenCode / Codex / Claude Code integration

Proposed default (untested): talk to each provider through structured
interfaces (OpenCode server API, Codex app-server, Claude Code SDK/bridge),
never by parsing terminal text. Approval requests bind to exact request IDs.

- Owner: provider adapters (one owner per provider).
- Evidence needed: against current versions, enumerate each provider's actual
  capabilities: session start/resume, event streams, permission prompts,
  interruption, diff delivery. Produce the provider capability matrix named in
  P1 deliverables. Note version pinning, since these CLIs change fast.
- Pass criteria: a written capability matrix per provider with tested
  endpoints/methods, known gaps, and a resumption answer; features absent from
  the API are listed as unsupported rather than approximated.
- Available: nothing probed. No API calls made, no capability facts collected.
- Missing: installed provider binaries at pinned versions, probes, the matrix
  itself.
- If it fails: adapters shrink to what the APIs support; some approval
  guarantees may be impossible for a given provider, which the UI must then
  disable with an explanation (per P8).

## Gate 4: Private network reachability

Proposed default (untested): user installs Tailscale; phone and agent talk
over the tailnet; no relay in MVP; backend is control plane only.

- Owner: connectivity (within backend scope).
- Evidence needed: a physical phone and a Windows agent on separate networks
  join a tailnet and hold a stable WebSocket under real conditions: sleep/
  resume of the PC, phone network switch (wifi to cellular), multi-minute
  disconnect and reconnect. Measure reconnect time against the 5 s snapshot
  target in the plan.
- Pass criteria: reconnect succeeds within documented bounds on all tested
  network transitions; DERP-relay behavior understood and acceptable; setup
  steps a non-expert user can follow are written down.
- Available: no tailnet set up for this project, no devices joined, no
  measurements.
- Missing: Tailscale accounts, physical phone testing, a reachability test
  rig, and reconnect-time data.
- If it fails: the relay moves from post-MVP to required scope, which changes
  backend design and pricing assumptions.

## Gate 5: Trust revocation freshness and recovery

Proposed default (untested): revocation propagates from backend through the
control channel; new commands fail closed without fresh trust; locally
running work continues; recovery uses phone-generated recovery material
(P10) and never a password as the trust root.

- Owner: contracts/security.
- Evidence needed: a design-level trust spec plus tests: revoke a device and
  measure the worst-case window before it loses authorization across
  connectivity states (online, offline agent, offline phone); verify replay
  protection against captured grant material; verify recovery works with the
  phone destroyed and no computer-only secret.
- Pass criteria: documented maximum revocation window per connectivity
  state, agreed as acceptable; fail-closed behavior demonstrated for new
  commands; recovery path exercised end to end without the lost device.
- Available: nothing. The trust spec does not exist yet; no revocation or
  recovery test has run.
- Missing: the signed grant/revocation format, test fixtures, and an external
  design review (planned for P12 but the spec needs an early pass).
- If it fails: the phone-first trust model needs rework before P3/P4 pairing
  and auth build on it.

---

## What must happen for this file to change

Each gate closes only when its evidence exists and its pass criteria are
demonstrated on real hardware or real provider versions, with the device
model, versions, and conditions recorded. Until then, all five gates are open,
and downstream phases (P2 contracts especially) inherit that uncertainty.
