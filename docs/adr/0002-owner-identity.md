# ADR 0002: Owner Identity (Local Only for MVP)

## Status

Accepted (P1). Implements DEC-020. Answers the PRD section 50 account-vs-local question for MVP.

## Context

PRD section 50 asks whether an account or cloud identity is required for initial Owner establishment. PRD sections 7, 12-19, and 49 make the first trusted phone the sole trust authority: the Owner Device holds the Owner private key, authorizes computers and further phones, and anchors recovery. PRD section 37 requires minimizing data stored outside user devices. PLAN.md P1 must decide local-only versus account binding because it determines backend identity surface, onboarding flow, and what recovery anchors to.

## Decision

- Owner establishment is local-only for MVP. The Owner identity (keypair, Owner id) is created on the phone. No cloud account, email, or third-party identity is required to install, establish Owner, lock the app with device authentication, and pair the first computer.
- The Owner private key never leaves the phone (Android Keystore / iOS Keychain + Secure Enclave, per ADR 0001). It never appears on the PC or backend in usable form.
- Recovery material is generated on the phone, outside the PC trust boundary. It must not exist only on the Windows computer. Losing the Owner phone means recovering via that phone-generated material (rotation/replacement flow in P2); there is no cloud password reset for MVP.
- Account binding (email/OAuth/cloud backup, multi-phone account recovery, team identity) is deferred to post-MVP.

## Alternatives considered

- Required cloud account at first run: simpler recovery and cross-device login, but adds a third-party dependency, a new attack surface, backend PII storage, and onboarding friction. Rejected for MVP because it contradicts the privacy-minimization rule and is not needed to prove phone-first trust.
- Optional account from day one alongside local Owner: tempting compromise, but doubles the identity paths P2-P3 must prove (attacker-PC, replay, revocation tests times two auth roots). Deferred so P2 proves exactly one authority first.
- PC-held or backend-held recovery backup: rejected. A compromised PC or backend breach would capture the recovery path; PRD section 18 forbids recovery material living only (or authoritatively) inside the PC boundary.

## Consequences

- Backend stores an Owner id and public key plus a recovery descriptor (pointer/metadata) only, never recovery secrets or private keys.
- P2 owns: exact recovery credential type, generation UX, storage guidance, rotation, and the replacement-Owner flow with revocation of the lost device.
- Known cost, accepted: losing both the phone and the recovery material means losing ownership. This is stated in-app during setup rather than papered over with a backend backdoor.
- Post-MVP account binding must preserve the invariant that a computer never authorizes a phone, and must not silently escrow the Owner private key. Revisit in its own ADR.
- Open: recovery UX wording and descriptor schema (P2/P3 contract work).
