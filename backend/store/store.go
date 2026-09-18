// Package store defines the backend control-plane persistence seam.
//
// One interface, two physical backends: durable control truth lives in
// PostgreSQL, ephemeral coordination state lives in Redis with TTLs.
// Implementations own atomicity: multi-step transitions must fail closed.
// See docs/trust/pairing-spec.md for the ceremony this persists.
package store

import (
	"context"
	"errors"
	"time"
)

// Device roles. Only phones and the Owner flow can ever grant trust;
// computers can only ever submit join requests (PLAN P2 invariant I1).
const (
	RoleOwnerPhone   = "owner_phone"
	RoleTrustedPhone = "trusted_phone"
	RoleComputer     = "computer"
)

// Pairing session states. Approved, rejected, and expired are terminal and
// latch into consumed: a session id is usable at most once (PLAN P2).
const (
	SessionPending  = "pending"
	SessionApproved = "approved"
	SessionRejected = "rejected"
	SessionExpired  = "expired"
	SessionConsumed = "consumed"
)

var (
	ErrNotFound  = errors.New("store: not found")
	ErrConflict  = errors.New("store: already exists")
	ErrExpired   = errors.New("store: expired")
	ErrGone      = errors.New("store: already consumed")
	ErrForbidden = errors.New("store: forbidden")
	ErrReplayed  = errors.New("store: request id already used")
)

// Device is a registered phone or computer. Private keys are never stored;
// only the public key plus fingerprint travel here.
type Device struct {
	ID           string
	UserID       string
	Role         string
	DisplayName  string
	PubKey       []byte
	Fingerprint  string
	AuthorizedBy string
	Revoked      bool
	LastSeenAt   time.Time
}

// PairingSession is the durable audit row for a phone-created session.
// Live single-use enforcement also lives in Redis; this row is the backup.
type PairingSession struct {
	ID              string
	UserID          string
	CreatedBy       string
	Status          string
	ExpiresAt       time.Time
	QRNonce         string
	JoinPubKey      []byte
	JoinFingerprint string
	JoinName        string
	JoinRequestID   string
}

// TrustGrant is an append-only Owner-signed authorization. Rows are never
// updated, only superseded by revocation.
type TrustGrant struct {
	SubjectDeviceID string
	GranterDeviceID string
	PayloadHash     []byte
	Signature       []byte
	CreatedAt       time.Time
}

// Presence is last-seen plus online flag. TTL-derived: crashes fail to
// offline, never stuck online.
type Presence struct {
	DeviceID string
	Online   bool
	ConnID   string
	LastSeen time.Time
}

// Attention is a minimal push hint: ids and kind only, never content.
type Attention struct {
	ComputerID string
	WorkflowID string
	Kind       string
}

// Store is the full control-plane seam. Durable methods must survive
// process restarts; ephemeral methods may be TTL-backed.
type Store interface {
	// Users and devices (durable).
	CreateUser(ctx context.Context) (string, error)
	RegisterDevice(ctx context.Context, d Device) error
	GetDevice(ctx context.Context, id string) (Device, error)
	ListUserDevices(ctx context.Context, userID string) ([]Device, error)
	RevokeDevice(ctx context.Context, id, revokedBy, reason string) error
	IsRevoked(ctx context.Context, deviceID string) (bool, error)

	// Pairing coordination. DecidePairingSession must atomically consume
	// the session and record the grant on approve; any second use of the
	// same session id fails with ErrGone, use after expiry with ErrExpired.
	CreatePairingSession(ctx context.Context, s PairingSession) error
	GetPairingSession(ctx context.Context, id string) (PairingSession, error)
	SubmitJoinRequest(ctx context.Context, sessionID string, pubKey []byte, fingerprint, displayName, requestID string) error
	DecidePairingSession(ctx context.Context, sessionID string, approve bool, subjectPubKey, granterSig []byte, granterDeviceID string) error

	// Trust grants (durable, append-only).
	RecordGrant(ctx context.Context, g TrustGrant) error

	// Auth challenges and opaque access tokens (ephemeral).
	IssueChallenge(ctx context.Context, deviceID string) (string, error)
	ConsumeChallenge(ctx context.Context, deviceID, challenge string) error
	IssueAccessToken(ctx context.Context, deviceID, userID string, ttl time.Duration) (string, error)
	ResolveAccessToken(ctx context.Context, token string) (deviceID, userID string, err error)
	RevokeDeviceTokens(ctx context.Context, deviceID string) error

	// Presence, push, attention, replay (ephemeral).
	SetPresence(ctx context.Context, p Presence) error
	GetPresence(ctx context.Context, deviceID string) (Presence, error)
	SetPushToken(ctx context.Context, deviceID, platform, token string) error
	EnqueueAttention(ctx context.Context, userID string, a Attention) error
	// CheckAndMarkRequest returns ErrReplayed when requestID was seen
	// within ttl, otherwise records it and returns nil.
	CheckAndMarkRequest(ctx context.Context, requestID string, ttl time.Duration) error

	// Ping reports backend dependency health for readyz.
	Ping(ctx context.Context) error
}
