# ADR 0001: Crypto Suite

## Status

Accepted (P1). Implements DEC-019. Exact message formats, authorization record shape, and session establishment to be frozen in the P1 proto contract; exact Dart lib pinned in P2.

## Context

PRD sections 12-19 and 32-37 require: asymmetric device identity, Owner-signed authorization records binding pubkey + session + Owner + context, authenticated encrypted transport, replay protection, expiry, revocation, and private keys that never leave their owning boundary. PRD section 33 names Ed25519-style signing and X25519-style key exchange as candidates and requires established libraries, never custom primitives. PRD section 50 leaves algorithms, message formats, rotation, session establishment, and authorization records as open decisions. P1 must lock a suite the Rust agent, Go backend, and Dart mobile can all implement against.

## Decision

- Signing: Ed25519 for device identity keys and Owner authorization records (grants, revocations).
- Key exchange: X25519 (ephemeral) for session establishment.
- Transport: TLS 1.3 for all control traffic (phone-backend, agent-backend, phone-agent over mesh or relay). End-to-end authorization checks still apply above TLS: sender pubkey must be trusted and unrevoked, request must carry a fresh id.
- Libraries: established implementations only. No custom primitives, no custom curves, no hand-rolled framing.
  - Rust (agent): ed25519-dalek, x25519-dalek, rustls.
  - Go (backend): x/crypto (ed25519, curve25519) plus stdlib TLS (crypto/tls, minimum TLS 1.3 where policy allows; TLS 1.2 floor only where the platform forces it, to be recorded in P2).
  - Dart/Flutter (mobile): cryptography package or pinenacl family; exact lib pinned in P2 after API and hardware-backing check.
  - P-256 kept as documented fallback only if hardware (Secure Enclave / StrongBox) or platform WebCrypto forces it. Fallback does not change the authorization record shape, only the algorithm identifier field.
- Key storage (sealed, never exported in usable form):
  - Android: Android Keystore, StrongBox where present, TEE fallback policy defined in P2.
  - iOS: Keychain, Secure Enclave where present.
  - Windows: DPAPI plus TPM-backed capabilities where present.
  - Backend holds public keys only, never private keys or recovery secrets.
- Rotation for MVP: re-pair. A compromised or replaced key is revoked and the device re-pairs through a fresh phone-created session and Owner approval. No in-place key rollover protocol in MVP.
- Replay protection (all sensitive requests): uuid request id + timestamp + expiry + seen-id cache. Pairing sessions are short-lived (5-10 min), single-use. Approval requests are single-resolve (pending to approved/rejected/expired/superseded, single resolve wins). Backend keeps replay ids in Redis with TTL; agent keeps a seen-id cache. Reused, expired, or already-resolved ids are rejected.

## Alternatives considered

- P-256/ECDSA as primary: wider hardware support (Secure Enclave, StrongBox, TPM 2.0), but larger signature complexity and less uniform library behavior across Rust/Go/Dart. Kept as fallback, not primary.
- Age/Noise-style custom handshake: stronger E2E story over relay, but more design surface and no P1 need since TLS 1.3 plus signed authorization records already satisfy MVP guarantees. Deferred to relay E2E design post-MVP.
- Custom crypto or QR-secret-derived keys: rejected. Violates PRD section 33 and makes QR (a session reference, never trust) into key material.

## Consequences

- P1 proto must define: algorithm identifiers (ed25519 default, p256 fallback tag), public key encoding, authorization/grant record fields (subject pubkey, session id, Owner id, context, timestamp, expiry, signature), revocation record, and WS envelope fields (protocol version, msg id, sender, timestamp, nonce).
- P2 must pin the exact Dart library, the Keystore StrongBox-vs-TEE policy, Secure Enclave usage conditions, DPAPI+TPM behavior where TPM is absent, TLS version floor per path, and the seen-id cache sizes/TTLs.
- Re-pair rotation is simple but user-visible; any smoother rotation waits for post-MVP and must preserve the invariant that a PC never authorizes a phone.
- Open: exact byte formats, session-establishment message order, and fallback trigger criteria. All belong to the P1 contract + P2 proof, not this ADR.
