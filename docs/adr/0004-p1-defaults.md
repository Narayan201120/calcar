# ADR 0004: P1 Defaults (Network, Relay, Events, Min OS)

## Status

Accepted (P1). Implements DEC-021 (defaults half). Locks the bounded defaults P1 is allowed to set; each gets proved or revised in its owning phase.

## Context

PRD sections 9.7-9.9 (WebSockets, Tailscale/WireGuard first, no public SSH, FCM/APNs), 21/25 (provider events, approval lifecycle), 38 (thin client, old-phone reach), and 50 (network architecture, adapter event scope, min OS versions) leave four choices open that downstream work cannot start without: how phone and PC connect in MVP, what the relay is, which events are frozen in proto v1, and which phones are supported. PLAN.md P1 says: decide crypto, Owner identity, and persistence split firmly; the rest stay as bounded options with a default.

## Decision

- Network, mesh first: Tailscale or WireGuard for direct private connectivity in MVP. No public SSH exposure required. SSH may exist as an administrative/transport option but is never the trust basis (identity comes from keys + Owner grant, never IP/hostname/Device ID).
- Relay: stubbed `501 Not Implemented` with a stable schema in MVP. The proto/HTTP surface for relay (request/response fields, error code, E2E expectations) is reserved now so a later relay does not break the contract, but no relay traffic path ships in MVP. If a relay is ever introduced, what passes through it and how E2E encryption is maintained gets its own ADR.
- Event set, minimal PRD list frozen for proto v1: agent/workflow started, command started, command completed, file changed, approval required, user input required, error occurred, workflow completed, workflow stopped. Approval lifecycle: pending to approved/rejected/expired/superseded, single resolve wins. Commands carry idempotency keys; destructive actions need a second confirm. Richer file/terminal streaming stays inside provider adapters and bounded tails, not as new top-level guarantees.
- Min OS hypothesis (to validate, not to ship blindly): Android 10+ and iOS 16+. Rationale: lowest plausible floor that still gives hardware-backed keys (Keystore/StrongBox-or-TEE, Keychain/Secure Enclave), current FCM/APNs push, Flutter stable support, and TLS 1.2+ with modern suites. P6 validates on a 3-4 GB Android device and an older iPhone against secure-hardware availability, push delivery, and the 80-200 MB foreground RSS envelope; the floor rises only if secure hardware or push is missing.

## Alternatives considered

- Relay-first or relay-complete in MVP: rejected. Adds E2E design, TURN-scale ops, and content-routing privacy risk before direct mesh is proven. Stub-with-schema keeps the option without the cost.
- Public SSH as primary transport: rejected. Conflicts with PRD non-goal (no required public SSH) and confuses transport access with device trust.
- Rich event set in v1 (full terminal streaming, full file sync, analytics events): rejected. Freezes UI and adapter choices too early and threatens thin-client memory caps. Additive minor proto changes can extend later; breaking changes mean v2.
- Lower OS floor (older Android/iOS) from day one: rejected as a promise. Reach is a goal, but shipping below hardware-key and push support would hollow out ADR 0001/0002. Hypothesis-plus-measurement is the compromise.

## Consequences

- P1 proto reserves relay fields and freezes the minimal event + approval + idempotency shape; CI enforces additive-only minors and unknown-field tolerance.
- P7 thin slice runs over mesh (one PC, one provider + generic) covering view, command, approval round-trip, disconnect, and reconnect-resume.
- P6 owns the min-OS verdict with real-device evidence; if the hypothesis fails, this ADR is amended with measured floor + reason, not silently lowered.
- Open: relay E2E design, richer event additions, exact OS floor. Each belongs to its proving phase, tracked as decision tickets in PLAN.md.
