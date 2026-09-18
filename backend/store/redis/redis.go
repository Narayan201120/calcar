// Package redis backs the ephemeral half of the store seam with Redis via
// go-redis v9. Every key carries a TTL so crashes fail to offline, unconsumed,
// and logged-out instead of stuck. Durable truth (users, devices, grants,
// revocations) lives in Postgres and reports an explicit error here; see
// backend/store.NewStore for the combined wiring.
package redis

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	goredis "github.com/redis/go-redis/v9"

	"github.com/calcar/calcar/backend/store"
)

// Key namespaces and TTLs.
const (
	keyPairing    = "pairing:"
	keyPresence   = "presence:"
	keyConn       = "conn:"
	keyToken      = "tokens:"
	keyTokenIndex = "tokens_by_device:"
	keyChallenge  = "challenges:"
	keyReplay     = "replay:"
	keyNotify     = "notify:"
	keyPushTokens = "pushtokens:"

	presenceTTL  = 90 * time.Second
	challengeTTL = 5 * time.Minute
	notifyTrim   = 100
	// consumedKeep lingers decided pairing tombstones past the decision so a
	// retried second decide still fails closed with ErrGone from Redis.
	consumedKeep = 24 * time.Hour
)

var _ store.Store = (*Store)(nil)

var errNeedsPostgres = errors.New("redis: durable state needs the postgres store; use store.NewStore")

// Store is the Redis half of the store seam.
type Store struct {
	cli *goredis.Client
}

// NewStore dials addr (host:port) and pings.
func NewStore(ctx context.Context, addr string) (*Store, error) {
	cli := goredis.NewClient(&goredis.Options{Addr: addr})
	if err := cli.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis: ping: %w", err)
	}
	return &Store{cli: cli}, nil
}

// Close drains the client.
func (s *Store) Close() error { return s.cli.Close() }

func pairingKey(id string) string    { return keyPairing + id }
func presenceKey(id string) string   { return keyPresence + id }
func connKey(id string) string       { return keyConn + id }
func tokenKey(tok string) string     { return keyToken + tok }
func tokenIndexKey(id string) string { return keyTokenIndex + id }
func challengeKey(id string) string  { return keyChallenge + id }
func replayKey(id string) string     { return keyReplay + id }
func notifyKey(user string) string   { return keyNotify + user }
func pushTokensKey(id string) string { return keyPushTokens + id }

// encodeAttention packs ids and kind only, never content.
func encodeAttention(a store.Attention) string {
	return strings.Join([]string{a.ComputerID, a.WorkflowID, a.Kind}, "\x1f")
}

// decodeAttention unpacks encodeAttention output.
func decodeAttention(raw string) store.Attention {
	parts := strings.SplitN(raw, "\x1f", 3)
	a := store.Attention{}
	if len(parts) > 0 {
		a.ComputerID = parts[0]
	}
	if len(parts) > 1 {
		a.WorkflowID = parts[1]
	}
	if len(parts) > 2 {
		a.Kind = parts[2]
	}
	return a
}

// --- durable methods: owned by Postgres ---

func (s *Store) CreateUser(ctx context.Context) (string, error) { return "", errNeedsPostgres }

func (s *Store) RegisterDevice(ctx context.Context, d store.Device) error { return errNeedsPostgres }

func (s *Store) GetDevice(ctx context.Context, id string) (store.Device, error) {
	return store.Device{}, errNeedsPostgres
}

func (s *Store) ListUserDevices(ctx context.Context, userID string) ([]store.Device, error) {
	return nil, errNeedsPostgres
}

func (s *Store) RevokeDevice(ctx context.Context, id, revokedBy, reason string) error {
	return errNeedsPostgres
}

func (s *Store) IsRevoked(ctx context.Context, deviceID string) (bool, error) {
	return false, errNeedsPostgres
}

func (s *Store) RecordGrant(ctx context.Context, g store.TrustGrant) error { return errNeedsPostgres }

// --- pairing coordination: live single-use state with TTL ---

func sessionTTL(expiresAt time.Time) time.Duration {
	ttl := time.Until(expiresAt)
	if ttl <= 0 {
		return 0
	}
	return ttl
}

// CreatePairingSession stores the live session with a TTL to its expiry.
// Creating an already-expired session fails closed with ErrExpired.
func (s *Store) CreatePairingSession(ctx context.Context, sess store.PairingSession) error {
	if sess.ID == "" {
		return fmt.Errorf("%w: session id is required", store.ErrConflict)
	}
	ttl := sessionTTL(sess.ExpiresAt)
	if ttl <= 0 {
		return store.ErrExpired
	}
	status := sess.Status
	if status == "" {
		status = store.SessionPending
	}
	created := sess.CreatedBy
	fields := map[string]any{
		"user_id":    sess.UserID,
		"created_by": created,
		"status":     status,
		"expires_at": sess.ExpiresAt.UTC().Unix(),
		"qr_nonce":   sess.QRNonce,
	}
	ok, err := s.cli.HSetNX(ctx, pairingKey(sess.ID), "status", status).Result()
	if err != nil {
		return fmt.Errorf("redis: create pairing: %w", err)
	}
	if !ok {
		return store.ErrConflict
	}
	if err := s.cli.HSet(ctx, pairingKey(sess.ID), fields).Err(); err != nil {
		return fmt.Errorf("redis: create pairing: %w", err)
	}
	if err := s.cli.Expire(ctx, pairingKey(sess.ID), ttl).Err(); err != nil {
		return fmt.Errorf("redis: create pairing: %w", err)
	}
	return nil
}

// readSession loads the live hash. Missing keys report ErrNotFound; callers
// that need expired-vs-unknown precision consult the Postgres audit row.
func (s *Store) readSession(ctx context.Context, id string) (store.PairingSession, error) {
	m, err := s.cli.HGetAll(ctx, pairingKey(id)).Result()
	if err != nil {
		return store.PairingSession{}, fmt.Errorf("redis: read pairing: %w", err)
	}
	if len(m) == 0 {
		return store.PairingSession{}, store.ErrNotFound
	}
	var sess store.PairingSession
	sess.ID = id
	sess.UserID = m["user_id"]
	sess.CreatedBy = m["created_by"]
	sess.Status = m["status"]
	sess.QRNonce = m["qr_nonce"]
	sess.JoinFingerprint = m["join_fp"]
	sess.JoinName = m["join_name"]
	sess.JoinRequestID = m["join_req"]
	if v := m["expires_at"]; v != "" {
		if unix, err := strconv.ParseInt(v, 10, 64); err == nil {
			sess.ExpiresAt = time.Unix(unix, 0).UTC()
		}
	}
	if v := m["join_pub"]; v != "" {
		if raw, err := hex.DecodeString(v); err == nil {
			sess.JoinPubKey = raw
		}
	}
	return sess, nil
}

// GetPairingSession returns live state. A pending session past its wall-clock
// expiry reports ErrExpired.
func (s *Store) GetPairingSession(ctx context.Context, id string) (store.PairingSession, error) {
	sess, err := s.readSession(ctx, id)
	if err != nil {
		return store.PairingSession{}, err
	}
	if sess.Status == store.SessionPending && sessionTTL(sess.ExpiresAt) <= 0 {
		return sess, store.ErrExpired
	}
	return sess, nil
}

// SubmitJoinRequest records the single join. Only a live pending session with
// no recorded join accepts one; everything else fails closed.
func (s *Store) SubmitJoinRequest(ctx context.Context, sessionID string, pubKey []byte,
	fingerprint, displayName, requestID string,
) error {
	if len(pubKey) == 0 || requestID == "" {
		return fmt.Errorf("%w: pubkey and request id are required", store.ErrConflict)
	}
	sess, err := s.readSession(ctx, sessionID)
	if err != nil {
		return err
	}
	if sess.Status != store.SessionPending {
		return store.ErrGone
	}
	if ttl := sessionTTL(sess.ExpiresAt); ttl <= 0 {
		return store.ErrExpired
	}
	if sess.JoinRequestID != "" {
		return store.ErrGone
	}
	ok, err := s.cli.HSetNX(ctx, pairingKey(sessionID), "join_req", requestID).Result()
	if err != nil {
		return fmt.Errorf("redis: submit join: %w", err)
	}
	if !ok {
		return store.ErrGone
	}
	ttl, err := s.cli.TTL(ctx, pairingKey(sessionID)).Result()
	if err != nil {
		return fmt.Errorf("redis: submit join: %w", err)
	}
	if err := s.cli.HSet(ctx, pairingKey(sessionID), map[string]any{
		"join_pub":  hex.EncodeToString(pubKey),
		"join_fp":   fingerprint,
		"join_name": displayName,
	}).Err(); err != nil {
		return fmt.Errorf("redis: submit join: %w", err)
	}
	if ttl > 0 {
		_ = s.cli.Expire(ctx, pairingKey(sessionID), ttl).Err()
	}
	return nil
}

// DecidePairingSession flips a live pending session to approved or rejected.
// Approve requires the subject pubkey to match the recorded join exactly
// (PUBKEY_MISMATCH leaves the session pending); any second decision fails
// with ErrGone. The decided hash lingers as a tombstone past TTL.
func (s *Store) DecidePairingSession(ctx context.Context, sessionID string, approve bool,
	subjectPubKey, _ []byte, granterDeviceID string,
) error {
	sess, err := s.readSession(ctx, sessionID)
	if err != nil {
		return err
	}
	if sess.Status != store.SessionPending {
		return store.ErrGone
	}
	if ttl := sessionTTL(sess.ExpiresAt); ttl <= 0 {
		return store.ErrExpired
	}
	if approve {
		if len(sess.JoinPubKey) == 0 || string(subjectPubKey) != string(sess.JoinPubKey) {
			return fmt.Errorf("%w: subject pubkey differs from join pubkey", store.ErrConflict)
		}
	}
	next := store.SessionRejected
	if approve {
		next = store.SessionApproved
	}
	if err := s.cli.HSet(ctx, pairingKey(sessionID), map[string]any{
		"status":     next,
		"granter":    granterDeviceID,
		"decided_at": time.Now().UTC().Unix(),
	}).Err(); err != nil {
		return fmt.Errorf("redis: decide pairing: %w", err)
	}
	_ = s.cli.Expire(ctx, pairingKey(sessionID), consumedKeep).Err()
	return nil
}

// CheckPairingLive fails closed when the session is missing, terminal, or
// past expiry. The combined store calls this before the Postgres decide.
func (s *Store) CheckPairingLive(ctx context.Context, id string) error {
	sess, err := s.readSession(ctx, id)
	if err != nil {
		return err
	}
	if sess.Status != store.SessionPending {
		return store.ErrGone
	}
	if ttl := sessionTTL(sess.ExpiresAt); ttl <= 0 {
		return store.ErrExpired
	}
	return nil
}

// MarkPairingConsumed stamps a terminal status tombstone that lingers past the
// original TTL, so retries against a decided session keep failing closed with
// ErrGone even when the live hash is gone.
func (s *Store) MarkPairingConsumed(ctx context.Context, id, status string) error {
	if status == "" {
		status = store.SessionConsumed
	}
	if err := s.cli.HSet(ctx, pairingKey(id), map[string]any{
		"status":     status,
		"decided_at": time.Now().UTC().Unix(),
	}).Err(); err != nil {
		return fmt.Errorf("redis: mark consumed: %w", err)
	}
	_ = s.cli.Expire(ctx, pairingKey(id), consumedKeep).Err()
	return nil
}

// --- challenges and tokens ---

func newToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("redis: random token: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// IssueChallenge mints a 128-bit challenge bound to the device for 5 minutes.
func (s *Store) IssueChallenge(ctx context.Context, deviceID string) (string, error) {
	if deviceID == "" {
		return "", fmt.Errorf("%w: device id is required", store.ErrConflict)
	}
	ch, err := newToken()
	if err != nil {
		return "", err
	}
	if err := s.cli.Set(ctx, challengeKey(deviceID), ch, challengeTTL).Err(); err != nil {
		return "", fmt.Errorf("redis: issue challenge: %w", err)
	}
	return ch, nil
}

// ConsumeChallenge checks the challenge and deletes it. Single use: a second
// consume reports ErrNotFound, a wrong value ErrConflict.
func (s *Store) ConsumeChallenge(ctx context.Context, deviceID, challenge string) error {
	key := challengeKey(deviceID)
	got, err := s.cli.Get(ctx, key).Result()
	if errors.Is(err, goredis.Nil) {
		return store.ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("redis: consume challenge: %w", err)
	}
	if got != challenge {
		return fmt.Errorf("%w: challenge mismatch", store.ErrConflict)
	}
	if err := s.cli.Del(ctx, key).Err(); err != nil {
		return fmt.Errorf("redis: consume challenge: %w", err)
	}
	return nil
}

// IssueAccessToken mints an opaque bearer bound to device plus user.
func (s *Store) IssueAccessToken(ctx context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	if deviceID == "" || userID == "" || ttl <= 0 {
		return "", fmt.Errorf("%w: device, user, and positive ttl are required", store.ErrConflict)
	}
	tok, err := newToken()
	if err != nil {
		return "", err
	}
	if err := s.cli.HSet(ctx, tokenKey(tok), map[string]any{
		"device_id": deviceID,
		"user_id":   userID,
	}).Err(); err != nil {
		return "", fmt.Errorf("redis: issue token: %w", err)
	}
	if err := s.cli.Expire(ctx, tokenKey(tok), ttl).Err(); err != nil {
		return "", fmt.Errorf("redis: issue token: %w", err)
	}
	if err := s.cli.SAdd(ctx, tokenIndexKey(deviceID), tok).Err(); err != nil {
		return "", fmt.Errorf("redis: issue token: %w", err)
	}
	_ = s.cli.Expire(ctx, tokenIndexKey(deviceID), ttl+time.Hour).Err()
	return tok, nil
}

// ResolveAccessToken maps a bearer to device plus user, or ErrNotFound.
func (s *Store) ResolveAccessToken(ctx context.Context, token string) (string, string, error) {
	m, err := s.cli.HGetAll(ctx, tokenKey(token)).Result()
	if errors.Is(err, goredis.Nil) || len(m) == 0 {
		return "", "", store.ErrNotFound
	}
	if err != nil {
		return "", "", fmt.Errorf("redis: resolve token: %w", err)
	}
	return m["device_id"], m["user_id"], nil
}

// RevokeDeviceTokens drops every live token for a device. Already-gone tokens
// stay gone: revoking twice is nil.
func (s *Store) RevokeDeviceTokens(ctx context.Context, deviceID string) error {
	toks, err := s.cli.SMembers(ctx, tokenIndexKey(deviceID)).Result()
	if err != nil {
		return fmt.Errorf("redis: revoke tokens: %w", err)
	}
	pipe := s.cli.Pipeline()
	for _, t := range toks {
		pipe.Del(ctx, tokenKey(t))
	}
	pipe.Del(ctx, tokenIndexKey(deviceID))
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("redis: revoke tokens: %w", err)
	}
	return nil
}

// --- presence, push, attention, replay ---

// SetPresence writes presence with a 90s TTL plus the conn lookup. Missing
// heartbeats age out to offline; nothing sticks online after a crash.
func (s *Store) SetPresence(ctx context.Context, p store.Presence) error {
	if p.DeviceID == "" || p.ConnID == "" {
		return fmt.Errorf("%w: device and conn ids are required", store.ErrConflict)
	}
	online := "0"
	if p.Online {
		online = "1"
	}
	if err := s.cli.HSet(ctx, presenceKey(p.DeviceID), map[string]any{
		"online":    online,
		"conn_id":   p.ConnID,
		"last_seen": time.Now().UTC().Unix(),
	}).Err(); err != nil {
		return fmt.Errorf("redis: set presence: %w", err)
	}
	if err := s.cli.Expire(ctx, presenceKey(p.DeviceID), presenceTTL).Err(); err != nil {
		return fmt.Errorf("redis: set presence: %w", err)
	}
	if err := s.cli.Set(ctx, connKey(p.ConnID), p.DeviceID, presenceTTL).Err(); err != nil {
		return fmt.Errorf("redis: set presence: %w", err)
	}
	return nil
}

// GetPresence reads live presence. An expired key is offline, never an error:
// unknown devices report Online false with ErrNotFound so callers can tell
// "never seen" apart from "seen but aged out".
func (s *Store) GetPresence(ctx context.Context, deviceID string) (store.Presence, error) {
	m, err := s.cli.HGetAll(ctx, presenceKey(deviceID)).Result()
	if err != nil {
		return store.Presence{}, fmt.Errorf("redis: get presence: %w", err)
	}
	if len(m) == 0 {
		return store.Presence{DeviceID: deviceID}, store.ErrNotFound
	}
	p := store.Presence{DeviceID: deviceID, Online: m["online"] == "1", ConnID: m["conn_id"]}
	if v := m["last_seen"]; v != "" {
		if unix, err := strconv.ParseInt(v, 10, 64); err == nil {
			p.LastSeen = time.Unix(unix, 0).UTC()
		}
	}
	return p, nil
}

// LookupConn resolves a conn id to its device, or ErrNotFound.
func (s *Store) LookupConn(ctx context.Context, connID string) (string, error) {
	deviceID, err := s.cli.Get(ctx, connKey(connID)).Result()
	if errors.Is(err, goredis.Nil) {
		return "", store.ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("redis: lookup conn: %w", err)
	}
	return deviceID, nil
}

// SetPushToken stores the live push token in the per-device hash.
func (s *Store) SetPushToken(ctx context.Context, deviceID, platform, token string) error {
	if deviceID == "" || platform == "" || token == "" {
		return fmt.Errorf("%w: device, platform, and token are required", store.ErrConflict)
	}
	if err := s.cli.HSet(ctx, pushTokensKey(deviceID), platform, token).Err(); err != nil {
		return fmt.Errorf("redis: set push token: %w", err)
	}
	return nil
}

// EnqueueAttention pushes a minimal notify hint (ids and kind only) and trims
// the per-user list to the newest 100.
func (s *Store) EnqueueAttention(ctx context.Context, userID string, a store.Attention) error {
	if userID == "" {
		return fmt.Errorf("%w: user id is required", store.ErrConflict)
	}
	key := notifyKey(userID)
	if err := s.cli.RPush(ctx, key, encodeAttention(a)).Err(); err != nil {
		return fmt.Errorf("redis: enqueue attention: %w", err)
	}
	if err := s.cli.LTrim(ctx, key, -notifyTrim, -1).Err(); err != nil {
		return fmt.Errorf("redis: enqueue attention: %w", err)
	}
	return nil
}

// CheckAndMarkRequest records requestID for ttl with SET NX. Reuse inside the
// window fails with ErrReplayed; retries must reuse the idempotency key.
func (s *Store) CheckAndMarkRequest(ctx context.Context, requestID string, ttl time.Duration) error {
	if requestID == "" || ttl <= 0 {
		return fmt.Errorf("%w: request id and positive ttl are required", store.ErrConflict)
	}
	ok, err := s.cli.SetNX(ctx, replayKey(requestID), "1", ttl).Result()
	if err != nil {
		return fmt.Errorf("redis: replay check: %w", err)
	}
	if !ok {
		return store.ErrReplayed
	}
	return nil
}

// Ping reports Redis health for readyz.
func (s *Store) Ping(ctx context.Context) error {
	if err := s.cli.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("redis: ping: %w", err)
	}
	return nil
}
