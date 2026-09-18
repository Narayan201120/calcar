//go:build integration

// Integration tests for the Postgres half plus the combined store against
// live Postgres and Redis. Reads PG_DSN (default
// postgres://postgres@localhost:5432/calcar_test?sslmode=disable) and
// REDIS_ADDR (default localhost:6379). Migrations run first; tests fail
// closed (no skip) when a backend is unreachable.
package postgres_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/calcar/calcar/backend/store"
	pgstore "github.com/calcar/calcar/backend/store/postgres"
	rdstore "github.com/calcar/calcar/backend/store/redis"
)

func pgDSN() string {
	if v := os.Getenv("PG_DSN"); v != "" {
		return v
	}
	return "postgres://postgres@localhost:5432/calcar_test?sslmode=disable"
}

func redisAddr() string {
	if v := os.Getenv("REDIS_ADDR"); v != "" {
		return v
	}
	return "localhost:6379"
}

func randHex(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return hex.EncodeToString(b)
}

func testID(t *testing.T, prefix string) string {
	t.Helper()
	return fmt.Sprintf("%s-%d-%s", prefix, time.Now().UnixNano(), randHex(t, 4))
}

func mustPG(t *testing.T) *pgstore.Store {
	t.Helper()
	ctx := context.Background()
	if err := pgstore.Migrate(ctx, pgDSN()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	s, err := pgstore.NewStore(ctx, pgDSN())
	if err != nil {
		t.Fatalf("open pg: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func mustCombined(t *testing.T) store.Store {
	t.Helper()
	ctx := context.Background()
	pg := mustPG(t)
	rd, err := rdstore.NewStore(ctx, redisAddr())
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	t.Cleanup(func() { _ = rd.Close() })
	c := store.NewStore(pg, rd)
	if err := c.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	return c
}

func testPubKey(t *testing.T, seed byte) []byte {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatalf("rand: %v", err)
	}
	k[0] = seed
	return k
}

func TestIntegrationRegisterListRevoke(t *testing.T) {
	ctx := context.Background()
	s := mustPG(t)
	user, err := s.CreateUser(ctx)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	owner := store.Device{ID: testID(t, "owner"), UserID: user, Role: store.RoleOwnerPhone,
		DisplayName: "Owner", PubKey: testPubKey(t, 1), Fingerprint: "AA"}
	pc := store.Device{ID: testID(t, "pc"), UserID: user, Role: store.RoleComputer,
		DisplayName: "PC", PubKey: testPubKey(t, 2), Fingerprint: "BB", AuthorizedBy: owner.ID}
	if err := s.RegisterDevice(ctx, owner); err != nil {
		t.Fatalf("register owner: %v", err)
	}
	if err := s.RegisterDevice(ctx, pc); err != nil {
		t.Fatalf("register pc: %v", err)
	}
	// Duplicate id and duplicate (user, pubkey) both conflict.
	if err := s.RegisterDevice(ctx, pc); !errors.Is(err, store.ErrConflict) {
		t.Errorf("duplicate device err = %v, want ErrConflict", err)
	}
	if err := s.RegisterDevice(ctx, store.Device{ID: testID(t, "pc2"), UserID: user,
		Role: store.RoleComputer, PubKey: pc.PubKey}); !errors.Is(err, store.ErrConflict) {
		t.Errorf("duplicate pubkey err = %v, want ErrConflict", err)
	}
	if err := s.RegisterDevice(ctx, store.Device{ID: testID(t, "bad"), UserID: user,
		Role: "admin", PubKey: testPubKey(t, 3)}); !errors.Is(err, store.ErrConflict) {
		t.Errorf("bad role err = %v, want ErrConflict", err)
	}

	devs, err := s.ListUserDevices(ctx, user)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(devs) != 2 {
		t.Fatalf("listed %d devices, want 2", len(devs))
	}

	if revoked, err := s.IsRevoked(ctx, pc.ID); err != nil || revoked {
		t.Fatalf("revoked before revoke = %v, %v", revoked, err)
	}
	if err := s.RevokeDevice(ctx, pc.ID, owner.ID, "lost laptop"); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if revoked, err := s.IsRevoked(ctx, pc.ID); err != nil || !revoked {
		t.Fatalf("revoked after revoke = %v, %v", revoked, err)
	}
	got, err := s.GetDevice(ctx, pc.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !got.Revoked {
		t.Error("device flag not flipped")
	}
	if err := s.RevokeDevice(ctx, "no-such-device", owner.ID, "x"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("revoke unknown err = %v, want ErrNotFound", err)
	}
}

func TestIntegrationPairingHappyPath(t *testing.T) {
	ctx := context.Background()
	c := mustCombined(t)
	user, err := c.CreateUser(ctx)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	ownerID := testID(t, "owner")
	pcID := testID(t, "pc")
	ownerKey := testPubKey(t, 11)
	pcKey := testPubKey(t, 12)
	if err := c.RegisterDevice(ctx, store.Device{ID: ownerID, UserID: user,
		Role: store.RoleOwnerPhone, DisplayName: "Owner", PubKey: ownerKey}); err != nil {
		t.Fatalf("register owner: %v", err)
	}
	if err := c.RegisterDevice(ctx, store.Device{ID: pcID, UserID: user,
		Role: store.RoleComputer, DisplayName: "Desk", PubKey: pcKey, AuthorizedBy: ownerID}); err != nil {
		t.Fatalf("register pc: %v", err)
	}

	before := grantCount(t, ownerID)
	sessID := testID(t, "sess")
	if err := c.CreatePairingSession(ctx, store.PairingSession{
		ID: sessID, UserID: user, CreatedBy: ownerID,
		Status: store.SessionPending, ExpiresAt: time.Now().Add(10 * time.Minute),
		QRNonce: "nonce-1",
	}); err != nil {
		t.Fatalf("create session: %v", err)
	}
	joinReq := testID(t, "req")
	if err := c.SubmitJoinRequest(ctx, sessID, pcKey, "FP-PC", "Desk", joinReq); err != nil {
		t.Fatalf("join: %v", err)
	}
	// Second join on the same session is consumed, even with a fresh id.
	if err := c.SubmitJoinRequest(ctx, sessID, pcKey, "FP-PC", "Desk", testID(t, "req")); !errors.Is(err, store.ErrGone) {
		t.Fatalf("second join err = %v, want ErrGone", err)
	}
	if err := c.DecidePairingSession(ctx, sessID, true, pcKey, []byte("granter-sig"), ownerID); err != nil {
		t.Fatalf("decide approve: %v", err)
	}
	sess, err := c.GetPairingSession(ctx, sessID)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	if sess.Status != store.SessionApproved {
		t.Errorf("status = %q, want approved", sess.Status)
	}
	if n := grantCount(t, ownerID); n != before+1 {
		t.Errorf("grants for owner = %d, want %d", n, before+1)
	}
	if subj := grantSubject(t, ownerID); subj != pcID {
		t.Errorf("grant subject = %q, want %q (pre-registered pc)", subj, pcID)
	}
	// Double decide fails closed.
	if err := c.DecidePairingSession(ctx, sessID, true, pcKey, []byte("x"), ownerID); !errors.Is(err, store.ErrGone) {
		t.Errorf("double decide err = %v, want ErrGone", err)
	}
	if n := grantCount(t, ownerID); n != before+1 {
		t.Errorf("double decide wrote a second grant (count %d)", n)
	}
}

func TestIntegrationPairingWrongPubkey(t *testing.T) {
	ctx := context.Background()
	c := mustCombined(t)
	user, err := c.CreateUser(ctx)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	sessID := testID(t, "sess")
	if err := c.CreatePairingSession(ctx, store.PairingSession{
		ID: sessID, UserID: user, ExpiresAt: time.Now().Add(10 * time.Minute),
	}); err != nil {
		t.Fatalf("create session: %v", err)
	}
	joinKey := testPubKey(t, 21)
	if err := c.SubmitJoinRequest(ctx, sessID, joinKey, "FP", "PC", testID(t, "req")); err != nil {
		t.Fatalf("join: %v", err)
	}
	// Approve with a swapped key: PUBKEY_MISMATCH, no grant, still pending.
	if err := c.DecidePairingSession(ctx, sessID, true, testPubKey(t, 22), []byte("sig"), "owner"); !errors.Is(err, store.ErrConflict) {
		t.Fatalf("swapped pubkey err = %v, want ErrConflict", err)
	}
	sess, err := c.GetPairingSession(ctx, sessID)
	if err != nil {
		t.Fatalf("get session: %v", err)
	}
	if sess.Status != store.SessionPending {
		t.Fatalf("status = %q, want pending after mismatch", sess.Status)
	}
	// Owner can still reject afterwards.
	if err := c.DecidePairingSession(ctx, sessID, false, nil, nil, "owner"); err != nil {
		t.Fatalf("reject after mismatch: %v", err)
	}
}

func TestIntegrationPairingExpired(t *testing.T) {
	ctx := context.Background()
	pg := mustPG(t)

	// Postgres-level: an already-expired audit row rejects the join.
	user, err := pg.CreateUser(ctx)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	old := testID(t, "sess")
	if err := pg.CreatePairingSession(ctx, store.PairingSession{
		ID: old, UserID: user, ExpiresAt: time.Now().Add(-time.Minute),
	}); err != nil {
		t.Fatalf("create expired session: %v", err)
	}
	err = pg.SubmitJoinRequest(ctx, old, testPubKey(t, 31), "FP", "PC", testID(t, "req"))
	if !errors.Is(err, store.ErrExpired) {
		t.Errorf("expired join err = %v, want ErrExpired", err)
	}
	if _, err := pg.GetPairingSession(ctx, old); err != nil {
		t.Errorf("expired get err = %v, want row with terminal status", err)
	}

	// Combined-level: a live session whose TTL fires rejects the join.
	c := mustCombined(t)
	user2, err := c.CreateUser(ctx)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	short := testID(t, "sess")
	if err := c.CreatePairingSession(ctx, store.PairingSession{
		ID: short, UserID: user2, ExpiresAt: time.Now().Add(2 * time.Second),
	}); err != nil {
		t.Fatalf("create session: %v", err)
	}
	time.Sleep(3 * time.Second)
	err = c.SubmitJoinRequest(ctx, short, testPubKey(t, 32), "FP", "PC", testID(t, "req"))
	if !errors.Is(err, store.ErrExpired) {
		t.Errorf("post-TTL join err = %v, want ErrExpired", err)
	}
}

func TestIntegrationPairingUnknown(t *testing.T) {
	ctx := context.Background()
	c := mustCombined(t)
	err := c.SubmitJoinRequest(ctx, "no-such-session", testPubKey(t, 41), "FP", "PC", testID(t, "req"))
	if !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown session join err = %v, want ErrNotFound", err)
	}
}

func grantCount(t *testing.T, granter string) int {
	t.Helper()
	conn, err := pgx.Connect(context.Background(), pgDSN())
	if err != nil {
		t.Fatalf("direct pg: %v", err)
	}
	defer conn.Close(context.Background())
	var n int
	if err := conn.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM trust_grants WHERE granter_device_id = $1`, granter).Scan(&n); err != nil {
		t.Fatalf("count grants: %v", err)
	}
	return n
}

func grantSubject(t *testing.T, granter string) string {
	t.Helper()
	conn, err := pgx.Connect(context.Background(), pgDSN())
	if err != nil {
		t.Fatalf("direct pg: %v", err)
	}
	defer conn.Close(context.Background())
	var subj string
	if err := conn.QueryRow(context.Background(),
		`SELECT subject_device_id FROM trust_grants
		 WHERE granter_device_id = $1 ORDER BY id DESC LIMIT 1`, granter).Scan(&subj); err != nil {
		t.Fatalf("grant subject: %v", err)
	}
	return subj
}
