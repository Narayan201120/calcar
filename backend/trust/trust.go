// Package trust is the P2 trust conformance core.
//
// It implements the executable half of docs/trust/pairing-spec.md:
// device fingerprints, device ids, AuthorizationRecord signing payloads,
// authorization verification, pairing session state, replay defence, and
// single-resolve approval state.
//
// Pure functions and in-memory state only. No I/O, no clocks, no private
// keys except the explicitly test-only signer below. Callers pass wall
// clock millis in; P3 wires these helpers to Postgres plus Redis.
package trust

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"sync"

	"google.golang.org/protobuf/proto"

	calcarv1 "github.com/calcar/calcar/backend/gen/calcar/v1"
)

// Timing defaults. All values are milliseconds.
const (
	// PairingTTLMillis is the pairing session TTL: 10 minutes (DEC-024).
	PairingTTLMillis int64 = 10 * 60 * 1000
	// MaxClockSkewMillis bounds acceptable clock difference: +/- 5 minutes
	// per the pairing spec sections 5 and 7.
	MaxClockSkewMillis int64 = 5 * 60 * 1000
	// ChallengeTTLMillis is the device-key challenge expiry: 2 minutes.
	ChallengeTTLMillis int64 = 2 * 60 * 1000
	// TokenTTLMillis is the short-lived auth token lifetime: 15 minutes.
	TokenTTLMillis int64 = 15 * 60 * 1000
)

// Stable error codes. Pairing codes match the pairing spec error table.
const (
	CodePairingExpired   = "PAIRING_EXPIRED"
	CodePairingConsumed  = "PAIRING_CONSUMED"
	CodeUnknownSession   = "UNKNOWN_SESSION"
	CodePubkeyMismatch   = "PUBKEY_MISMATCH"
	CodeRevoked          = "REVOKED"
	CodeNotOwner         = "NOT_OWNER"
	CodeReplayedID       = "REPLAYED_ID"
	CodeBadSignature     = "BAD_SIGNATURE"
	CodeUnknownApproval  = "UNKNOWN_APPROVAL"
	CodeApprovalExpired  = "APPROVAL_EXPIRED"
	CodeApprovalResolved = "APPROVAL_RESOLVED"
	CodeInvalidInput     = "INVALID_INPUT"
	CodeQRMismatch       = "QR_MISMATCH"
)

// TrustError is a coded failure. Code is stable for P3 transport mapping.
type TrustError struct {
	Code string
	Msg  string
}

func (e *TrustError) Error() string { return e.Code + ": " + e.Msg }

// ErrorCode returns the stable code for err, or "" when err is not coded.
func ErrorCode(err error) string {
	var te *TrustError
	if errors.As(err, &te) {
		return te.Code
	}
	return ""
}

func coded(code, msg string) *TrustError { return &TrustError{Code: code, Msg: msg} }

// FingerprintEd25519Pub derives the human-readable fingerprint of a 32-byte
// Ed25519 public key: uppercase hex of SHA-256, grouped in fours.
//
// Example: A91C 7D24 ... (16 groups for a 32-byte digest).
func FingerprintEd25519Pub(pub []byte) (string, error) {
	if len(pub) != ed25519.PublicKeySize {
		return "", coded(CodeInvalidInput, "public key must be 32 bytes")
	}
	sum := sha256.Sum256(pub)
	hexed := strings.ToUpper(hex.EncodeToString(sum[:]))
	groups := make([]string, 0, 16)
	for i := 0; i < len(hexed); i += 4 {
		groups = append(groups, hexed[i:i+4])
	}
	return strings.Join(groups, " "), nil
}

// DeviceIDForComputer derives a stable display and routing id from a 32-byte
// Ed25519 computer public key: RD-WIN- plus 8 uppercase hex chars taken from
// the first 4 bytes of SHA-256(pub).
//
// The id identifies and routes only. It never authenticates (PRD 35).
func DeviceIDForComputer(pub []byte) (string, error) {
	if len(pub) != ed25519.PublicKeySize {
		return "", coded(CodeInvalidInput, "public key must be 32 bytes")
	}
	sum := sha256.Sum256(pub)
	return "RD-WIN-" + strings.ToUpper(hex.EncodeToString(sum[:4])), nil
}

// ContextHash binds the human context the Owner saw at approval time:
// display name, fingerprint, subject device id, session id, and the join
// request time. Fields are joined with 0x00 separators and the request time
// is decimal millis, then hashed with SHA-256.
func ContextHash(displayName, fingerprint, subjectDeviceID, sessionID string, requestedAtMillis int64) []byte {
	var b strings.Builder
	b.WriteString(displayName)
	b.WriteByte(0x00)
	b.WriteString(fingerprint)
	b.WriteByte(0x00)
	b.WriteString(subjectDeviceID)
	b.WriteByte(0x00)
	b.WriteString(sessionID)
	b.WriteByte(0x00)
	b.WriteString(strconv.FormatInt(requestedAtMillis, 10))
	sum := sha256.Sum256([]byte(b.String()))
	out := make([]byte, len(sum))
	copy(out, sum[:])
	return out
}

// SigningPayload returns the bytes the Owner signs: the AuthorizationRecord
// serialized with deterministic protobuf serialization and owner_signature
// cleared (field 7 zeroed). Verifiers re-derive the same bytes.
func SigningPayload(rec *calcarv1.AuthorizationRecord) ([]byte, error) {
	if rec == nil {
		return nil, coded(CodeInvalidInput, "nil authorization record")
	}
	clone, ok := proto.Clone(rec).(*calcarv1.AuthorizationRecord)
	if !ok {
		return nil, coded(CodeInvalidInput, "not an authorization record")
	}
	clone.OwnerSignature = nil
	return proto.MarshalOptions{Deterministic: true}.Marshal(clone)
}

// SignAuthorizationForTest signs rec in place and returns the signature.
//
// TEST ONLY. Production Owner signing happens on the phone inside hardware
// key storage. The backend and the PC never hold the Owner private key.
func SignAuthorizationForTest(priv ed25519.PrivateKey, rec *calcarv1.AuthorizationRecord) ([]byte, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return nil, coded(CodeInvalidInput, "private key must be 64 bytes")
	}
	if rec == nil {
		return nil, coded(CodeInvalidInput, "nil authorization record")
	}
	payload, err := SigningPayload(rec)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(priv, payload)
	rec.OwnerSignature = append([]byte(nil), sig...)
	return sig, nil
}

// VerifyAuthorization checks an Owner-signed grant in task order:
// re-derive the signing payload and check the Owner signature, check the
// bound session id and subject pubkey against expected values, then check
// the decision timestamp is within ttlMillis and not skewed into the future.
//
// expectedContextHash, when non-empty, must equal rec.ContextHash exactly.
// nowMillis and ttlMillis are both millis; future skew beyond
// MaxClockSkewMillis fails.
func VerifyAuthorization(
	rec *calcarv1.AuthorizationRecord,
	ownerPub ed25519.PublicKey,
	expectedSessionID string,
	expectedSubjectPub []byte,
	expectedContextHash []byte,
	nowMillis int64,
	ttlMillis int64,
) error {
	if rec == nil {
		return coded(CodeInvalidInput, "nil authorization record")
	}
	if len(ownerPub) != ed25519.PublicKeySize {
		return coded(CodeNotOwner, "owner public key must be 32 bytes")
	}
	payload, err := SigningPayload(rec)
	if err != nil {
		return err
	}
	if len(rec.GetOwnerSignature()) != ed25519.SignatureSize {
		return coded(CodeBadSignature, "owner signature must be 64 bytes")
	}
	if !ed25519.Verify(ownerPub, payload, rec.GetOwnerSignature()) {
		return coded(CodeBadSignature, "owner signature invalid")
	}
	if expectedSessionID == "" || rec.GetSessionId() != expectedSessionID {
		return coded(CodeUnknownSession, "session binding mismatch")
	}
	if len(expectedSubjectPub) != ed25519.PublicKeySize ||
		!bytes.Equal(rec.GetSubjectPublicKey(), expectedSubjectPub) {
		return coded(CodePubkeyMismatch, "subject public key mismatch")
	}
	if len(rec.GetContextHash()) == 0 {
		return coded(CodeInvalidInput, "missing context hash")
	}
	if len(expectedContextHash) > 0 && !bytes.Equal(rec.GetContextHash(), expectedContextHash) {
		return coded(CodePubkeyMismatch, "context hash mismatch")
	}
	decided := rec.GetDecidedAtMillis()
	if decided <= 0 {
		return coded(CodeInvalidInput, "missing decided_at_millis")
	}
	if decided > nowMillis+MaxClockSkewMillis {
		return coded(CodeReplayedID, "decision timestamp skewed into the future")
	}
	if nowMillis-decided > ttlMillis {
		return coded(CodePairingExpired, "authorization outside TTL")
	}
	return nil
}

// SessionState is the pairing session lifecycle state.
type SessionState int32

const (
	SessionPending SessionState = iota + 1
	SessionApproved
	SessionRejected
	SessionExpired
	SessionConsumed
)

// String renders the state name for logs and errors.
func (s SessionState) String() string {
	switch s {
	case SessionPending:
		return "pending"
	case SessionApproved:
		return "approved"
	case SessionRejected:
		return "rejected"
	case SessionExpired:
		return "expired"
	case SessionConsumed:
		return "consumed"
	default:
		return "unknown"
	}
}

// Session is one phone-created pairing context with a 10-minute single-use
// latch. Terminal states never accept further transitions.
type Session struct {
	ID              string
	OwnerDeviceID   string
	CreatedAtMillis int64
	ExpiresAtMillis int64
	State           SessionState
}

// NewSession returns a pending session. Callers set ExpiresAtMillis to
// creation plus PairingTTLMillis.
func NewSession(id, ownerDeviceID string, createdAtMillis, expiresAtMillis int64) *Session {
	return &Session{
		ID:              id,
		OwnerDeviceID:   ownerDeviceID,
		CreatedAtMillis: createdAtMillis,
		ExpiresAtMillis: expiresAtMillis,
		State:           SessionPending,
	}
}

// IsExpired reports whether the TTL passed at nowMillis.
func (s *Session) IsExpired(nowMillis int64) bool {
	return nowMillis >= s.ExpiresAtMillis
}

// IsLive reports pending state with unreached expiry.
func (s *Session) IsLive(nowMillis int64) bool {
	return s.State == SessionPending && !s.IsExpired(nowMillis)
}

// CheckLive rejects joins and decisions against non-live sessions.
func (s *Session) CheckLive(nowMillis int64) error {
	if s.State == SessionConsumed {
		return coded(CodePairingConsumed, "session already consumed")
	}
	if s.State == SessionApproved || s.State == SessionRejected {
		return coded(CodePairingConsumed, "session already decided")
	}
	if s.State == SessionExpired || s.IsExpired(nowMillis) {
		return coded(CodePairingExpired, "session expired")
	}
	if s.State != SessionPending {
		return coded(CodePairingConsumed, "session not pending")
	}
	return nil
}

// Approve moves pending to approved. Any other state fails.
func (s *Session) Approve() error {
	if s.State == SessionExpired {
		return coded(CodePairingExpired, "session expired")
	}
	if s.State != SessionPending {
		return coded(CodePairingConsumed, "session not pending, state="+s.State.String())
	}
	s.State = SessionApproved
	return nil
}

// Reject moves pending to rejected. Any other state fails.
func (s *Session) Reject() error {
	if s.State == SessionExpired {
		return coded(CodePairingExpired, "session expired")
	}
	if s.State != SessionPending {
		return coded(CodePairingConsumed, "session not pending, state="+s.State.String())
	}
	s.State = SessionRejected
	return nil
}

// Expire moves pending to expired. Decided or consumed sessions fail.
func (s *Session) Expire() error {
	if s.State == SessionExpired {
		return coded(CodePairingExpired, "session already expired")
	}
	if s.State != SessionPending {
		return coded(CodePairingConsumed, "session not pending, state="+s.State.String())
	}
	s.State = SessionExpired
	return nil
}

// Consume applies the single-use latch after a decision or expiry.
// A second call always fails.
func (s *Session) Consume() error {
	if s.State == SessionConsumed {
		return coded(CodePairingConsumed, "session already consumed")
	}
	s.State = SessionConsumed
	return nil
}

// SessionStore is an in-memory session index. It stands in for the P3 Redis
// session lookup so unknown ids fail closed in the harness.
type SessionStore struct {
	mu       sync.Mutex
	sessions map[string]*Session
}

// NewSessionStore returns an empty store.
func NewSessionStore() *SessionStore {
	return &SessionStore{sessions: make(map[string]*Session)}
}

// Add indexes s. Empty ids and duplicate ids fail.
func (st *SessionStore) Add(s *Session) error {
	if s == nil || s.ID == "" {
		return coded(CodeInvalidInput, "session id required")
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if _, dup := st.sessions[s.ID]; dup {
		return coded(CodeReplayedID, "duplicate session id")
	}
	st.sessions[s.ID] = s
	return nil
}

// Get returns the session or UNKNOWN_SESSION when absent.
func (st *SessionStore) Get(id string) (*Session, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	s, ok := st.sessions[id]
	if !ok {
		return nil, coded(CodeUnknownSession, "unknown session")
	}
	return s, nil
}

// SeenIDs is a TTL replay cache for request ids, message ids, and nonces.
// An id added within its TTL is rejected on reuse; entries purge lazily and
// via Purge.
type SeenIDs struct {
	mu      sync.Mutex
	expires map[string]int64
}

// NewSeenIDs returns an empty cache.
func NewSeenIDs() *SeenIDs {
	return &SeenIDs{expires: make(map[string]int64)}
}

// Add records id for ttlMillis from nowMillis. Reuse inside the window fails
// with REPLAYED_ID. Empty ids fail.
func (c *SeenIDs) Add(id string, nowMillis, ttlMillis int64) error {
	if id == "" {
		return coded(CodeInvalidInput, "id required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if exp, ok := c.expires[id]; ok && exp > nowMillis {
		return coded(CodeReplayedID, "id already seen")
	}
	c.expires[id] = nowMillis + ttlMillis
	return nil
}

// Seen reports whether id is currently live in the cache.
func (c *SeenIDs) Seen(id string, nowMillis int64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	exp, ok := c.expires[id]
	return ok && exp > nowMillis
}

// Purge drops entries at or past nowMillis.
func (c *SeenIDs) Purge(nowMillis int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, exp := range c.expires {
		if exp <= nowMillis {
			delete(c.expires, id)
		}
	}
}

// ApprovalRegistry enforces single resolve: the first valid resolution wins.
// Late duplicates fail, resolves past expiry fail and latch the request
// expired, unknown ids fail.
type ApprovalRegistry struct {
	mu      sync.Mutex
	states  map[string]calcarv1.ApprovalState
	expires map[string]int64
}

// NewApprovalRegistry returns an empty registry.
func NewApprovalRegistry() *ApprovalRegistry {
	return &ApprovalRegistry{
		states:  make(map[string]calcarv1.ApprovalState),
		expires: make(map[string]int64),
	}
}

// Create registers a pending approval. Duplicate ids fail.
func (r *ApprovalRegistry) Create(approvalID string, expiresAtMillis int64) error {
	if approvalID == "" {
		return coded(CodeInvalidInput, "approval id required")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.states[approvalID]; dup {
		return coded(CodeReplayedID, "duplicate approval id")
	}
	r.states[approvalID] = calcarv1.ApprovalState_APPROVAL_STATE_PENDING
	r.expires[approvalID] = expiresAtMillis
	return nil
}

// Resolve applies one ALLOW or REJECT decision at nowMillis.
func (r *ApprovalRegistry) Resolve(
	approvalID string,
	decision calcarv1.ApprovalDecision,
	nowMillis int64,
) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, ok := r.states[approvalID]
	if !ok {
		return coded(CodeUnknownApproval, "unknown approval")
	}
	if state != calcarv1.ApprovalState_APPROVAL_STATE_PENDING {
		return coded(CodeApprovalResolved, "approval already resolved")
	}
	if nowMillis >= r.expires[approvalID] {
		r.states[approvalID] = calcarv1.ApprovalState_APPROVAL_STATE_EXPIRED
		return coded(CodeApprovalExpired, "approval expired")
	}
	switch decision {
	case calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW:
		r.states[approvalID] = calcarv1.ApprovalState_APPROVAL_STATE_APPROVED
	case calcarv1.ApprovalDecision_APPROVAL_DECISION_REJECT:
		r.states[approvalID] = calcarv1.ApprovalState_APPROVAL_STATE_REJECTED
	default:
		return coded(CodeInvalidInput, "decision must be ALLOW or REJECT")
	}
	return nil
}

// State returns the stored state and whether the id is known.
func (r *ApprovalRegistry) State(approvalID string) (calcarv1.ApprovalState, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.states[approvalID]
	return s, ok
}
