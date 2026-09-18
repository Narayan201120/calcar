package postgres

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/calcar/calcar/backend/store"
)

// Store is the PostgreSQL half of the store seam: everything durable.
// Ephemeral-only methods (challenges, tokens, replay, attention) return an
// explicit error here; wire Redis alongside via backend/store.NewStore.
type Store struct {
	pool *pgxpool.Pool
}

var _ store.Store = (*Store)(nil)

var errNeedsRedis = errors.New("postgres: ephemeral state needs the redis store; use store.NewStore")

// NewStore opens a pool and pings. Call Migrate first.
func NewStore(ctx context.Context, connString string) (*Store, error) {
	pool, err := pgxpool.New(ctx, connString)
	if err != nil {
		return nil, fmt.Errorf("postgres: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres: ping: %w", err)
	}
	return &Store{pool: pool}, nil
}

// Close drains the pool.
func (s *Store) Close() { s.pool.Close() }

// mapPgError converts common Postgres violations to seam errors.
func mapPgError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return store.ErrNotFound
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "23505": // unique_violation
			return fmt.Errorf("%w: %s", store.ErrConflict, pgErr.ConstraintName)
		case "23514": // check_violation (bad role or status)
			return fmt.Errorf("%w: %s", store.ErrConflict, pgErr.Message)
		case "23503": // foreign_key_violation
			return fmt.Errorf("%w: %s", store.ErrConflict, pgErr.Message)
		}
	}
	return err
}

func newUserID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("postgres: random user id: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// CreateUser inserts one user row and returns its id.
func (s *Store) CreateUser(ctx context.Context) (string, error) {
	id, err := newUserID()
	if err != nil {
		return "", err
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO users (id) VALUES ($1)`, id); err != nil {
		return "", mapPgError(err)
	}
	return id, nil
}

// RegisterDevice upserts nothing: a duplicate id or a duplicate
// (user_id, pubkey) pair fails with ErrConflict.
func (s *Store) RegisterDevice(ctx context.Context, d store.Device) error {
	if d.ID == "" || d.UserID == "" || len(d.PubKey) == 0 {
		return fmt.Errorf("%w: device id, user id, and pubkey are required", store.ErrConflict)
	}
	if d.Role != store.RoleOwnerPhone && d.Role != store.RoleTrustedPhone && d.Role != store.RoleComputer {
		return fmt.Errorf("%w: unknown role %q", store.ErrConflict, d.Role)
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO devices
		(id, user_id, role, display_name, pubkey, fingerprint, authorized_by, last_seen_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, now())`,
		d.ID, d.UserID, d.Role, d.DisplayName, d.PubKey, d.Fingerprint, d.AuthorizedBy)
	return mapPgError(err)
}

// GetDevice returns one device or ErrNotFound.
func (s *Store) GetDevice(ctx context.Context, id string) (store.Device, error) {
	var d store.Device
	var revoked bool
	err := s.pool.QueryRow(ctx, `SELECT id, user_id, role, display_name, pubkey,
		fingerprint, authorized_by, revoked, last_seen_at
		FROM devices WHERE id = $1`, id).Scan(
		&d.ID, &d.UserID, &d.Role, &d.DisplayName, &d.PubKey,
		&d.Fingerprint, &d.AuthorizedBy, &revoked, &d.LastSeenAt)
	if err != nil {
		return store.Device{}, mapPgError(err)
	}
	d.Revoked = revoked
	return d, nil
}

// ListUserDevices returns every device for a user in registration order.
func (s *Store) ListUserDevices(ctx context.Context, userID string) ([]store.Device, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, user_id, role, display_name, pubkey,
		fingerprint, authorized_by, revoked, last_seen_at
		FROM devices WHERE user_id = $1 ORDER BY created_at, id`, userID)
	if err != nil {
		return nil, mapPgError(err)
	}
	defer rows.Close()
	out := []store.Device{}
	for rows.Next() {
		var d store.Device
		var revoked bool
		if err := rows.Scan(&d.ID, &d.UserID, &d.Role, &d.DisplayName, &d.PubKey,
			&d.Fingerprint, &d.AuthorizedBy, &revoked, &d.LastSeenAt); err != nil {
			return nil, err
		}
		d.Revoked = revoked
		out = append(out, d)
	}
	return out, rows.Err()
}

// RevokeDevice appends a revocation record and flips the device flag in one
// transaction. Records are append-only: there is no un-revoke path.
func (s *Store) RevokeDevice(ctx context.Context, id, revokedBy, reason string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM devices WHERE id = $1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return store.ErrNotFound
	}
	if _, err := tx.Exec(ctx, `INSERT INTO revocations
		(subject_device_id, revoker_device_id, reason) VALUES ($1, $2, $3)`,
		id, revokedBy, reason); err != nil {
		return mapPgError(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE devices SET revoked = TRUE WHERE id = $1`, id); err != nil {
		return mapPgError(err)
	}
	return tx.Commit(ctx)
}

// IsRevoked reports durable revocation state: the device flag or any
// revocation record. Unknown devices report false, never an error.
func (s *Store) IsRevoked(ctx context.Context, deviceID string) (bool, error) {
	var revoked bool
	err := s.pool.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM devices WHERE id = $1 AND revoked
		UNION ALL
		SELECT 1 FROM revocations WHERE subject_device_id = $1
	)`, deviceID).Scan(&revoked)
	if err != nil {
		return false, mapPgError(err)
	}
	return revoked, nil
}

// CreatePairingSession writes the audit row. A duplicate id is ErrConflict.
func (s *Store) CreatePairingSession(ctx context.Context, sess store.PairingSession) error {
	if sess.ID == "" || sess.UserID == "" {
		return fmt.Errorf("%w: session id and user id are required", store.ErrConflict)
	}
	status := sess.Status
	if status == "" {
		status = store.SessionPending
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO pairing_sessions
		(id, user_id, created_by, status, expires_at, qr_nonce)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		sess.ID, sess.UserID, sess.CreatedBy, status, sess.ExpiresAt.UTC(), sess.QRNonce)
	return mapPgError(err)
}

type sessionRow struct {
	sess            store.PairingSession
	decidedAt       *time.Time
	granterDeviceID string
	hasJoin         bool
	hasRequestID    bool
}

// GetPairingSession returns the audit row. A pending row past its expiry is
// lazily flipped to expired so every reader sees terminal truth.
func (s *Store) GetPairingSession(ctx context.Context, id string) (store.PairingSession, error) {
	row, err := s.scanSession(ctx, s.pool, id)
	if err != nil {
		return store.PairingSession{}, err
	}
	if row.sess.Status == store.SessionPending && !time.Now().UTC().Before(row.sess.ExpiresAt) {
		if _, err := s.pool.Exec(ctx,
			`UPDATE pairing_sessions SET status = 'expired'
			 WHERE id = $1 AND status = 'pending'`, id); err != nil {
			return store.PairingSession{}, mapPgError(err)
		}
		row.sess.Status = store.SessionExpired
	}
	return row.sess, nil
}

func (s *Store) scanSession(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, id string) (sessionRow, error) {
	var r sessionRow
	var joinPub []byte
	var joinReq *string
	var decidedAt *time.Time
	var granterSig []byte
	err := q.QueryRow(ctx, `SELECT id, user_id, created_by, status, expires_at,
		qr_nonce, join_pubkey, join_fingerprint, join_name, join_request_id,
		decided_at, granter_device_id, granter_signature
		FROM pairing_sessions WHERE id = $1`, id).Scan(
		&r.sess.ID, &r.sess.UserID, &r.sess.CreatedBy, &r.sess.Status, &r.sess.ExpiresAt,
		&r.sess.QRNonce, &joinPub, &r.sess.JoinFingerprint, &r.sess.JoinName, &joinReq,
		&decidedAt, &r.granterDeviceID, &granterSig)
	if err != nil {
		return sessionRow{}, mapPgError(err)
	}
	if joinPub != nil {
		r.sess.JoinPubKey = append([]byte(nil), joinPub...)
		r.hasJoin = true
	}
	if joinReq != nil {
		r.sess.JoinRequestID = *joinReq
		r.hasRequestID = true
	}
	r.decidedAt = decidedAt
	return r, nil
}

// SubmitJoinRequest records the single join for a session. A second distinct
// join, a join against a decided session, and a join after expiry fail with
// ErrGone or ErrExpired; only the first join wins.
func (s *Store) SubmitJoinRequest(ctx context.Context, sessionID string, pubKey []byte,
	fingerprint, displayName, requestID string,
) error {
	if len(pubKey) == 0 || requestID == "" {
		return fmt.Errorf("%w: pubkey and request id are required", store.ErrConflict)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	row, err := s.scanSession(ctx, tx, sessionID)
	if err != nil {
		return err
	}
	switch {
	case row.sess.Status != store.SessionPending:
		return store.ErrGone
	case !time.Now().UTC().Before(row.sess.ExpiresAt):
		_, _ = tx.Exec(ctx, `UPDATE pairing_sessions SET status = 'expired'
			WHERE id = $1 AND status = 'pending'`, sessionID)
		_ = tx.Commit(ctx)
		return store.ErrExpired
	case row.hasJoin || row.hasRequestID:
		return store.ErrGone
	}
	ct, err := tx.Exec(ctx, `UPDATE pairing_sessions
		SET join_pubkey = $2, join_fingerprint = $3, join_name = $4, join_request_id = $5
		WHERE id = $1 AND status = 'pending' AND join_request_id IS NULL`,
		sessionID, pubKey, fingerprint, displayName, requestID)
	if err != nil {
		return mapPgError(err)
	}
	if ct.RowsAffected() == 0 {
		return store.ErrGone
	}
	if err := tx.Commit(ctx); err != nil {
		return mapPgError(err)
	}
	return nil
}

// DecidePairingSession atomically consumes the session and, on approve,
// records the grant. The row is re-read FOR UPDATE inside a transaction:
// pending plus unexpired plus exact join-pubkey match, or the decision fails
// with no state change (except lazy expiry). Any second use of the same id
// fails with ErrGone.
func (s *Store) DecidePairingSession(ctx context.Context, sessionID string, approve bool,
	subjectPubKey, granterSig []byte, granterDeviceID string,
) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var r sessionRow
	var joinPub []byte
	var decidedAt *time.Time
	var granterSigCol []byte
	var joinReq *string
	err = tx.QueryRow(ctx, `SELECT id, user_id, created_by, status, expires_at,
		qr_nonce, join_pubkey, join_fingerprint, join_name, join_request_id,
		decided_at, granter_device_id, granter_signature
		FROM pairing_sessions WHERE id = $1 FOR UPDATE`, sessionID).Scan(
		&r.sess.ID, &r.sess.UserID, &r.sess.CreatedBy, &r.sess.Status, &r.sess.ExpiresAt,
		&r.sess.QRNonce, &joinPub, &r.sess.JoinFingerprint, &r.sess.JoinName, &joinReq,
		&decidedAt, &r.granterDeviceID, &granterSigCol)
	if err != nil {
		return mapPgError(err)
	}
	if joinPub != nil {
		r.sess.JoinPubKey = append([]byte(nil), joinPub...)
		r.hasJoin = true
	}
	now := time.Now().UTC()
	switch {
	case r.sess.Status != store.SessionPending:
		return store.ErrGone
	case !now.Before(r.sess.ExpiresAt):
		if _, err := tx.Exec(ctx, `UPDATE pairing_sessions
			SET status = 'expired' WHERE id = $1`, sessionID); err != nil {
			return mapPgError(err)
		}
		if err := tx.Commit(ctx); err != nil {
			return mapPgError(err)
		}
		return store.ErrExpired
	}

	next := store.SessionRejected
	if approve {
		next = store.SessionApproved
		if !r.hasJoin {
			return fmt.Errorf("%w: approve needs a recorded join", store.ErrConflict)
		}
		if len(subjectPubKey) == 0 || string(subjectPubKey) != string(r.sess.JoinPubKey) {
			// PUBKEY_MISMATCH: no grant, session stays pending per the spec.
			return fmt.Errorf("%w: subject pubkey differs from join pubkey", store.ErrConflict)
		}
		subjectDeviceID := ""
		_ = tx.QueryRow(ctx, `SELECT id FROM devices
			WHERE user_id = $1 AND pubkey = $2`, r.sess.UserID, subjectPubKey).Scan(&subjectDeviceID)
		binding := grantBinding(sessionID, granterDeviceID, subjectPubKey)
		if _, err := tx.Exec(ctx, `INSERT INTO trust_grants
			(subject_device_id, granter_device_id, payload_hash, signature)
			VALUES ($1, $2, $3, $4)`,
			subjectDeviceID, granterDeviceID, binding, granterSig); err != nil {
			return mapPgError(err)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE pairing_sessions
		SET status = $2, decided_at = now(), granter_device_id = $3, granter_signature = $4
		WHERE id = $1`, sessionID, next, granterDeviceID, granterSig); err != nil {
		return mapPgError(err)
	}
	return tx.Commit(ctx)
}

// grantBinding binds the exact subject pubkey to the session and granter:
// SHA-256 over pubkey, session id, and granter id. The full signed record and
// its verification live above this layer; this hash is the durable binding.
func grantBinding(sessionID, granterDeviceID string, subjectPubKey []byte) []byte {
	h := sha256.New()
	h.Write(subjectPubKey)
	h.Write([]byte{0x00})
	h.Write([]byte(sessionID))
	h.Write([]byte{0x00})
	h.Write([]byte(granterDeviceID))
	return h.Sum(nil)
}

// RecordGrant appends one Owner-signed authorization. Rows are never updated.
func (s *Store) RecordGrant(ctx context.Context, g store.TrustGrant) error {
	if len(g.Signature) == 0 || len(g.PayloadHash) == 0 {
		return fmt.Errorf("%w: payload hash and signature are required", store.ErrConflict)
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO trust_grants
		(subject_device_id, granter_device_id, payload_hash, signature)
		VALUES ($1, $2, $3, $4)`,
		g.SubjectDeviceID, g.GranterDeviceID, g.PayloadHash, g.Signature)
	return mapPgError(err)
}

// SetPushToken upserts the durable push token backup. Live fan-out reads Redis.
func (s *Store) SetPushToken(ctx context.Context, deviceID, platform, token string) error {
	if deviceID == "" || platform == "" || token == "" {
		return fmt.Errorf("%w: device, platform, and token are required", store.ErrConflict)
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO push_tokens (device_id, platform, token, updated_at)
		VALUES ($1, $2, $3, now())
		ON CONFLICT (device_id, platform)
		DO UPDATE SET token = EXCLUDED.token, updated_at = now()`,
		deviceID, platform, token)
	return mapPgError(err)
}

// SetPresence records a durable last-seen trail in connection_metadata. Live
// online state with TTL lives in Redis; this row is audit only and never
// fails a heartbeat on its own (the combined store treats it best-effort).
func (s *Store) SetPresence(ctx context.Context, p store.Presence) error {
	if p.DeviceID == "" || p.ConnID == "" {
		return fmt.Errorf("%w: device and conn ids are required", store.ErrConflict)
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO connection_metadata
		(conn_id, device_id, last_seen_at) VALUES ($1, $2, now())
		ON CONFLICT (conn_id) DO UPDATE SET last_seen_at = now(), disconnected_at = NULL`,
		p.ConnID, p.DeviceID)
	return mapPgError(err)
}

// GetPresence returns the last durable sighting. Online state comes from Redis.
func (s *Store) GetPresence(ctx context.Context, deviceID string) (store.Presence, error) {
	var p store.Presence
	err := s.pool.QueryRow(ctx, `SELECT device_id, conn_id, last_seen_at
		FROM connection_metadata WHERE device_id = $1
		ORDER BY last_seen_at DESC LIMIT 1`, deviceID).Scan(&p.DeviceID, &p.ConnID, &p.LastSeen)
	if err != nil {
		return store.Presence{}, mapPgError(err)
	}
	return p, nil
}

// SetRecoveryDescriptor stores the opaque recovery descriptor for a user.
// Descriptor only: callers must never pass secrets or key material.
func (s *Store) SetRecoveryDescriptor(ctx context.Context, userID, descriptor string) error {
	if userID == "" || descriptor == "" {
		return fmt.Errorf("%w: user id and descriptor are required", store.ErrConflict)
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO recovery_config (user_id, descriptor, updated_at)
		VALUES ($1, $2, now())
		ON CONFLICT (user_id) DO UPDATE SET descriptor = EXCLUDED.descriptor, updated_at = now()`,
		userID, descriptor)
	return mapPgError(err)
}

// GetRecoveryDescriptor returns the stored descriptor or ErrNotFound.
func (s *Store) GetRecoveryDescriptor(ctx context.Context, userID string) (string, error) {
	var descriptor string
	if err := s.pool.QueryRow(ctx,
		`SELECT descriptor FROM recovery_config WHERE user_id = $1`, userID,
	).Scan(&descriptor); err != nil {
		return "", mapPgError(err)
	}
	return descriptor, nil
}

func (s *Store) IssueChallenge(ctx context.Context, deviceID string) (string, error) {
	return "", errNeedsRedis
}

func (s *Store) ConsumeChallenge(ctx context.Context, deviceID, challenge string) error {
	return errNeedsRedis
}

func (s *Store) IssueAccessToken(ctx context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	return "", errNeedsRedis
}

func (s *Store) ResolveAccessToken(ctx context.Context, token string) (string, string, error) {
	return "", "", errNeedsRedis
}

func (s *Store) RevokeDeviceTokens(ctx context.Context, deviceID string) error {
	return errNeedsRedis
}

func (s *Store) EnqueueAttention(ctx context.Context, userID string, a store.Attention) error {
	return errNeedsRedis
}

func (s *Store) CheckAndMarkRequest(ctx context.Context, requestID string, ttl time.Duration) error {
	return errNeedsRedis
}

// Ping reports Postgres health for readyz.
func (s *Store) Ping(ctx context.Context) error {
	if err := s.pool.Ping(ctx); err != nil {
		return fmt.Errorf("postgres: ping: %w", err)
	}
	return nil
}
