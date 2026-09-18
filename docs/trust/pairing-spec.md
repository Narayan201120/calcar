# Calcar pairing spec (P2, frozen)

Source of truth for first pairing. PRD sections 7, 12-19, 32-36. PLAN.md P2.
DEC-019 through DEC-024. Proto contract: `proto/calcar/v1/devices.proto`.

This document is normative prose. The executable form is the conformance
suite and fixed vectors under `backend/trust/` (tests plus vectors). If this
file and the suite disagree, the suite fails and this file is amended by
decision entry, not by silent edit.

No code in this spec. Field names match the proto exactly.

## 1. Roles

Three roles exist. No other role may sign, grant, or consume pairing state.

| Role | Holds | May do | May never do |
|------|-------|--------|--------------|
| Owner Device (first trusted phone) | Owner Ed25519 private key in hardware (Keystore / Keychain / Secure Enclave); local-only identity per DEC-020 | Create pairing session; approve or reject a join; sign AuthorizationRecord; sign Revocation | Export the Owner private key; approve without fresh device auth at signing time |
| Joining computer (managed PC) | Own Ed25519 keypair, generated locally, sealed with DPAPI plus TPM where present | Scan QR; submit one join request per session; prove key possession via challenge | Authorize any phone, itself, or another PC; sign trust on behalf of Owner |
| Backend (Go control plane) | No private keys of any device | Create and store session; validate liveness on join; relay join event to Owner; verify approver is the active Owner; verify subject pubkey matches join exactly; flip session to consumed; write device plus grant; enforce revocation on every auth | Grant trust on a computer's word alone; accept a join against a non-pending session; store workflow bodies, prompts, terminal, or keys |

## 2. Invariants (I1-I6)

- I1: The phone is the authority. Only an active Owner Device signs trust.
- I2: A computer requests authorization. It never grants it (PRD 14). A
  computer caller attempting grant or revoke gets rejected.
- I3: The QR code carries a session reference only. It never equals trust.
- I4: Device ID, display name, and fingerprint identify and route. None of
  them authenticate (PRD 35). Authentication is signature plus liveness plus
  revocation check.
- I5: Private keys stay in their owning boundary (PRD 49). The Owner private
  key never appears on the PC or the backend in usable form. The computer
  private key never leaves the computer.
- I6: Sessions expire and cannot be reused. Every grant binds the exact
  subject pubkey plus session plus Owner plus context. Any substitution fails.

## 3. QR payload, exact fields

The phone generates the QR after the user taps Add Computer. Encoding is a
single URI the PC camera scans:

`calcar://pair/v1?s=<session_id>&r=<rendezvous_url>&n=<nonce>&o=<owner_device_id>&v=1`

| Field | Meaning | Constraints |
|-------|---------|-------------|
| `v` | Format version. Fixed `1` for this spec | Unknown version: PC must refuse and show "update required", never guess |
| `s` | `PairingSession.session_id`, opaque | UUIDv4, single use (section 4) |
| `r` | Rendezvous URL of the backend pairing endpoint | HTTPS only; host pinned to configured backend; no query params of its own |
| `n` | QR nonce, 128-bit random, base64url | Binds the scanned image to the session record; mismatch with stored session nonce fails the join |
| `o` | `PairingSession.owner_device_id` | Routing hint only, never proof |

PC behavior on scan: parse, check `v == 1`, check `r` is HTTPS against the
configured backend, then call join over TLS. No trust is established at scan
time.

NOT in the QR: no AuthorizationRecord, no signature, no public key, no
private key, no auth token, no approval decision, no fingerprint, no device
name, no recovery material. Anything of that shape inside a QR image is
ignored and treated as malformed input.

## 4. Pairing session lifecycle

Single session object: `PairingSession` (`session_id`, `owner_device_id`,
`created_at_millis`, `expires_at_millis`, `consumed`).

TTL is 10 minutes from creation (DEC-024). The phone shows a live countdown.
Storage: Redis with TTL (DEC-021); Postgres holds the pairing audit row.

States:

```text
pending -> approved -> consumed
pending -> rejected -> consumed
pending -> expired (TTL reached, no decision; treated as consumed)
```

Rules:

1. `pending`: created, unconsumed, `now < expires_at_millis`. Only state that
   accepts a join request.
2. `approved`: Owner signed the AuthorizationRecord for the joined pubkey.
   Transition sets `consumed = true` atomically with writing device plus
   grant. Terminal.
3. `rejected`: Owner tapped Reject. Sets `consumed = true`, writes no trust.
   Terminal.
4. `expired`: wall clock passed `expires_at_millis` with no decision, or
   Redis TTL fired. Joins and decisions against it fail. Terminal. Phone shows
   Expired with a Regenerate action that mints a fresh session; the old id is
   never revived.
5. `consumed`: the single-use latch. Any second join, second approve, or
   approve-after-reject against the same `session_id` fails, even inside the
   TTL window. Double approve is the conformance case.

Atomicity: the approve path must flip pending to consumed and write the grant
in one transaction. A crash between the two must leave the session consumed
with no grant, never a grant with a reusable session.

## 5. Join request fields and binding rules

Message: `JoinRequest` (`request_id`, `session_id`, `device_id`,
`device_public_key`, `fingerprint`, `display_name`, `requested_at_millis`,
`nonce`).

Submission rules (backend validates all, in order):

1. `session_id` references a known session in state `pending`, unconsumed,
   unexpired. Else reject per the error table.
2. `request_id` is UUIDv4 and unseen (section 8). Reuse fails.
3. `device_public_key` is a 32-byte Ed25519 key (DEC-019) generated on the
   computer. Empty, wrong length, or non-canonical keys fail.
4. `fingerprint` must be the correct human-readable derivation of
   `device_public_key` shown on the approve card. Mismatch fails; the Owner
   sees what the key actually is, not what the PC claims its name is.
5. `display_name` is 1-64 chars, trimmed. Used for display only.
6. `device_id` is claimed routing id only. A spoofed or colliding id with no
   matching private key authenticates nothing; binding is to the pubkey, not
   the id.
7. `requested_at_millis` must be within +/- 5 minutes of backend clock and
   inside the session window. Outside fails as expired or skewed.
8. `nonce` is 128-bit fresh random per request. Reuse fails.
9. One join per session: a second distinct join against the same `session_id`
   fails as consumed even if the first join was never decided.

On accept, the backend emits the join event to the Owner phone and holds the
session in `pending` until decision or expiry.

## 6. Approve and reject card, exact fields

The phone displays this card on the join event, before any signing. Exact
fields, no more, no less:

```text
New computer wants to join Calcar

Computer: <display_name>
Device ID: <device_id, truncated with full value on tap>
Fingerprint: <fingerprint, grouped hex>
Requested: <relative time, e.g. Just now, plus absolute on tap>
Session expires in: <countdown mm:ss>

[ Reject ]  [ Approve ]
```

Approve requires fresh device auth (biometric or equivalent) at signing time
(PLAN P2). Reject requires the app to be unlocked but no fresh auth. Either
tap consumes the session. Expiry while the card is open disables both buttons
and shows Expired.

## 7. AuthorizationRecord signing (DEC-019, DEC-024)

Message: `AuthorizationRecord` (`authorization_id`, `session_id`,
`subject_device_id`, `subject_public_key`, `owner_device_id`,
`context_hash`, `owner_signature`, `decided_at_millis`, `nonce`).

Construction on approve:

1. `subject_public_key` is copied byte-for-byte from the accepted
   `JoinRequest.device_public_key`. Any difference, including re-encoding,
   fails verification.
2. `context_hash` is SHA-256 over the concatenation of `display_name`,
   `fingerprint`, `subject_device_id`, `session_id`, and
   `requested_at_millis` from the accepted join. It binds the human context
   the Owner actually saw.
3. `authorization_id` and `nonce` are fresh UUIDv4 / 128-bit random.
4. The Owner signs deterministic protobuf bytes of the record with
   `owner_signature` empty (field 7 zeroed) using Ed25519 (DEC-019, P-256 only
   as a recorded fallback, never mixed within one record).
5. `decided_at_millis` is Owner clock at tap time; backend rejects if outside
   the session window or beyond +/- 5 minutes skew.

Verification (backend, then any auditor): re-serialize the record with
`owner_signature` empty using deterministic protobuf serialization, check the
Ed25519 signature against the active Owner public key, check
`subject_public_key` equals the stored join pubkey exactly, check
`session_id` was pending and is now consumed by this grant, recompute and
compare `context_hash`. All checks must pass. Deterministic serialization
must hold across Dart, Rust, and Go codegen; the vector suite pins the bytes.

## 8. Challenge plus short-lived token transport (DEC-024)

No mTLS for MVP. Transport is TLS 1.3 plus application challenge-response
plus short-lived tokens:

1. After approval, the computer calls the session-result endpoint and learns
   it was approved (no key material in the response beyond its own ids).
2. Backend issues a 128-bit challenge nonce bound to the device id with a
   2-minute expiry.
3. The computer signs the challenge with its device private key (Ed25519) and
   returns the signature. Backend verifies against the registered
   `subject_public_key` and the revocation list.
4. On success the backend issues a short-lived opaque token (default 15
   minutes, refreshable while the device stays unrevoked). The token travels
   as a bearer over TLS on HTTP and as a handshake field on WebSocket.
5. Every request re-checks revocation (section 10). A revoked device gets no
   refresh and its current token dies at the next check.

Owner private key material never crosses this flow in either direction.

## 9. Replay rules

Applies to `request_id`, `message_id`, `nonce`, `idempotency_key` on pairing,
command, and approval messages (PRD 32):

1. Every sensitive request carries a UUID (`request_id` / `message_id`) plus a
   fresh `nonce` plus `sent_at` / `requested_at_millis`.
2. Receivers reject when: the id was seen before; the timestamp is outside
   +/- 5 minutes skew; the message is past its own expiry; the referenced
   session or approval is already resolved, expired, or consumed.
3. Seen-id cache lives in Redis on the backend and in memory plus SQLite on
   the agent (PLAN P2). Entries persist at least past the maximum skew plus
   TTL window so a replayed id cannot become valid again.
4. Retries reuse the same `idempotency_key` and are deduped to one effect;
   a new key with the same body is a new request and is evaluated fresh,
   which is why pairing sessions stay single use regardless of keys.

## 10. Revocation record, enforcement, propagation

Message: `Revocation` (`revocation_id`, `subject_device_id`,
`revoker_device_id`, `reason`, `revoked_at_millis`, `owner_signature`).

Shape rules: `revoker_device_id` must be an active Owner Device at signing
time; `reason` is short display text with no sensitive content; the Owner
signs deterministic protobuf bytes of the record with `owner_signature`
empty, same construction as section 7. Records are append-only in Postgres
(DEC-021); there is no delete or edit path.

Enforcement points:

- Backend: every authenticated HTTP call, every WebSocket handshake and
  heartbeat window, every pairing decision, every token refresh. Revoked
  subject fails closed.
- Agent: checks its cached trust state before accepting commands or approval
  resolutions from a phone and before opening the uplink; a revoked local
  identity stops initiating connections.

Propagation: revocation is durable state, not a UI action (PRD 19). Online
devices receive the revocation event over WebSocket and apply it immediately.
Offline devices apply it on the next reconnect or token refresh before any
other work; presence and missed-event replay happen only after the check
passes. A revoked computer keeps running local OS processes but loses all
Calcar access.

## 11. Rotation for MVP: re-pair only

No in-place key rotation in the MVP (DEC-024). Key change, key loss, or
suspected compromise means: Owner revokes the old device record, then runs a
fresh pairing session (10-minute single use) for the replacement identity.
The new identity gets a new `device_id` binding; the old pubkey is never
re-attached to a new id or vice versa.

## 12. Error table

Codes are stable strings returned alongside the transport status. Behavior is
fail closed with no state change unless noted.

| Case | Code | Transport behavior |
|------|------|--------------------|
| Join or decision after TTL | `PAIRING_EXPIRED` | 410 Gone; session terminal; phone shows Expired plus Regenerate |
| Second join or second decision on same session | `PAIRING_CONSUMED` | 410 Gone; first outcome stands; double approve never writes a second grant |
| Unknown `session_id` | `UNKNOWN_SESSION` | 404; no state change; logged without secrets |
| Grant pubkey differs from join pubkey, or fingerprint does not derive from pubkey | `PUBKEY_MISMATCH` | 422; no grant written; session stays pending until decided or expired |
| Subject or approver revoked, or approver is not the active Owner | `REVOKED` / `NOT_OWNER` | 401 or 403; token refused; WebSocket refused; computer caller attempting grant or revoke gets 403 |
| Reused `request_id`, `message_id`, or `nonce`; timestamp outside skew; message past its own expiry | `REPLAYED_ID` | 409; effect applied at most once; duplicate resolve of an approval reports superseded or expired |

## 13. Executable form

This file freezes intent. Proof lives in `backend/trust/`:

- Fixed vectors pin the QR field layout, one valid AuthorizationRecord with
  its deterministic bytes and signature, one tampered-pubkey negative, one
  expired-session negative, one consumed-session double-approve negative, one
  revocation record with enforcement order.
- The conformance harness asserts every invariant I1-I6, every row of the
  error table, and the P2 gate cases: attacker PC cannot authorize an
  attacker phone without an Owner tap; expired join fails; double approve
  fails; swapped pubkey fails; spoofed Device ID without the private key
  authenticates nothing; Owner private key never appears on PC or backend.

Full gate proof against live endpoints runs in P3. P2 exit is this spec plus
green vectors plus the seeded harness.
