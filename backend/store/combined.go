package store

import (
	"context"
	"time"
)

// sessionLatch is the Redis-side single-use latch for pairing sessions. The
// redis store implements it; the combined store detects it by assertion so
// this package never imports its own subpackages (which would cycle).
type sessionLatch interface {
	CheckPairingLive(ctx context.Context, id string) error
	MarkPairingConsumed(ctx context.Context, id, status string) error
}

// combined routes the seam: durable truth to pg, ephemeral coordination to
// rd. Pairing methods touch both: Redis enforces live single-use with TTL,
// Postgres keeps the audit row and the grant. Every partial failure fails
// closed toward consumed, never toward reusable.
type combined struct {
	pg Store
	rd Store
}

// NewStore wires a durable backend (Postgres) to an ephemeral backend (Redis)
// and returns the full seam. Callers construct each half in their own package.
func NewStore(pg, rd Store) Store {
	return &combined{pg: pg, rd: rd}
}

// latch reports the Redis latch when rd implements it.
func (c *combined) latch() (sessionLatch, bool) {
	l, ok := c.rd.(sessionLatch)
	return l, ok
}

func (c *combined) CreateUser(ctx context.Context) (string, error) {
	return c.pg.CreateUser(ctx)
}

func (c *combined) RegisterDevice(ctx context.Context, d Device) error {
	return c.pg.RegisterDevice(ctx, d)
}

func (c *combined) GetDevice(ctx context.Context, id string) (Device, error) {
	return c.pg.GetDevice(ctx, id)
}

func (c *combined) ListUserDevices(ctx context.Context, userID string) ([]Device, error) {
	return c.pg.ListUserDevices(ctx, userID)
}

func (c *combined) RevokeDevice(ctx context.Context, id, revokedBy, reason string) error {
	return c.pg.RevokeDevice(ctx, id, revokedBy, reason)
}

func (c *combined) IsRevoked(ctx context.Context, deviceID string) (bool, error) {
	return c.pg.IsRevoked(ctx, deviceID)
}

// CreatePairingSession writes the audit row first, then the live TTL entry.
// A Redis failure after the audit write returns an error and leaves the
// session unusable (fail closed); the audit row records the attempt.
func (c *combined) CreatePairingSession(ctx context.Context, s PairingSession) error {
	if err := c.pg.CreatePairingSession(ctx, s); err != nil {
		return err
	}
	if err := c.rd.CreatePairingSession(ctx, s); err != nil {
		return err
	}
	return nil
}

// GetPairingSession reads live state first and falls back to the audit row,
// so a session whose Redis TTL already fired still reports durable truth
// (including lazy expiry) instead of vanishing.
func (c *combined) GetPairingSession(ctx context.Context, id string) (PairingSession, error) {
	sess, err := c.rd.GetPairingSession(ctx, id)
	if err == nil {
		return sess, nil
	}
	if err != ErrNotFound {
		return sess, err
	}
	return c.pg.GetPairingSession(ctx, id)
}

// SubmitJoinRequest checks the live latch first, then records the audit row.
// A Redis hit that rejects the join never touches Postgres. When the live
// entry is gone but the audit row survives, Postgres arbitrates (expired or
// consumed instead of silently unknown).
func (c *combined) SubmitJoinRequest(ctx context.Context, sessionID string, pubKey []byte,
	fingerprint, displayName, requestID string,
) error {
	if err := c.rd.SubmitJoinRequest(ctx, sessionID, pubKey, fingerprint, displayName, requestID); err != nil {
		if err != ErrNotFound {
			return err
		}
		return c.pg.SubmitJoinRequest(ctx, sessionID, pubKey, fingerprint, displayName, requestID)
	}
	if err := c.pg.SubmitJoinRequest(ctx, sessionID, pubKey, fingerprint, displayName, requestID); err != nil {
		// Audit failed after the live join won: consume the live entry so the
		// session fails closed instead of accepting a decision with no audit.
		if l, ok := c.latch(); ok {
			_ = l.MarkPairingConsumed(ctx, sessionID, SessionConsumed)
		}
		return err
	}
	return nil
}

// DecidePairingSession checks the live latch, decides durably in Postgres
// (which re-reads FOR UPDATE, matches the join pubkey, and inserts the grant
// on approve), then marks the live entry consumed. Any Postgres failure also
// stamps a compensating consumed mark so Redis agrees the session is dead.
func (c *combined) DecidePairingSession(ctx context.Context, sessionID string, approve bool,
	subjectPubKey, granterSig []byte, granterDeviceID string,
) error {
	if l, ok := c.latch(); ok {
		if err := l.CheckPairingLive(ctx, sessionID); err != nil {
			if err != ErrNotFound {
				return err
			}
			// Live entry gone: let Postgres arbitrate from the audit row.
		}
	}
	if err := c.pg.DecidePairingSession(ctx, sessionID, approve, subjectPubKey, granterSig, granterDeviceID); err != nil {
		if l, ok := c.latch(); ok {
			_ = l.MarkPairingConsumed(ctx, sessionID, SessionConsumed)
		}
		return err
	}
	next := SessionRejected
	if approve {
		next = SessionApproved
	}
	if l, ok := c.latch(); ok {
		_ = l.MarkPairingConsumed(ctx, sessionID, next)
	}
	return nil
}

func (c *combined) RecordGrant(ctx context.Context, g TrustGrant) error {
	return c.pg.RecordGrant(ctx, g)
}

func (c *combined) IssueChallenge(ctx context.Context, deviceID string) (string, error) {
	return c.rd.IssueChallenge(ctx, deviceID)
}

func (c *combined) ConsumeChallenge(ctx context.Context, deviceID, challenge string) error {
	return c.rd.ConsumeChallenge(ctx, deviceID, challenge)
}

func (c *combined) IssueAccessToken(ctx context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	return c.rd.IssueAccessToken(ctx, deviceID, userID, ttl)
}

func (c *combined) ResolveAccessToken(ctx context.Context, token string) (string, string, error) {
	return c.rd.ResolveAccessToken(ctx, token)
}

func (c *combined) RevokeDeviceTokens(ctx context.Context, deviceID string) error {
	return c.rd.RevokeDeviceTokens(ctx, deviceID)
}

// SetPresence writes live TTL state, then best-effort audit. The audit write
// never fails a heartbeat: presence is inherently ephemeral and a Postgres
// blip must not mark devices offline.
func (c *combined) SetPresence(ctx context.Context, p Presence) error {
	if err := c.rd.SetPresence(ctx, p); err != nil {
		return err
	}
	_ = c.pg.SetPresence(ctx, p)
	return nil
}

// GetPresence reads live state first, then the durable last-seen trail.
func (c *combined) GetPresence(ctx context.Context, deviceID string) (Presence, error) {
	p, err := c.rd.GetPresence(ctx, deviceID)
	if err == nil {
		return p, nil
	}
	if err != ErrNotFound {
		return p, err
	}
	return c.pg.GetPresence(ctx, deviceID)
}

// SetPushToken writes both the live hash and the durable backup.
func (c *combined) SetPushToken(ctx context.Context, deviceID, platform, token string) error {
	if err := c.pg.SetPushToken(ctx, deviceID, platform, token); err != nil {
		return err
	}
	return c.rd.SetPushToken(ctx, deviceID, platform, token)
}

func (c *combined) EnqueueAttention(ctx context.Context, userID string, a Attention) error {
	return c.rd.EnqueueAttention(ctx, userID, a)
}

func (c *combined) CheckAndMarkRequest(ctx context.Context, requestID string, ttl time.Duration) error {
	return c.rd.CheckAndMarkRequest(ctx, requestID, ttl)
}

// Ping checks both backends for readyz and reports the first failure.
func (c *combined) Ping(ctx context.Context) error {
	if err := c.pg.Ping(ctx); err != nil {
		return err
	}
	return c.rd.Ping(ctx)
}
