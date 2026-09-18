// Command calcar-api runs the P3 HTTP control plane plus WS signals.
//
// Env: PORT (default 8080), PG_DSN, REDIS_ADDR, TOKEN_TTL (durations
// like "24h", default 24h).
//
// With PG_DSN and REDIS_ADDR set, main runs migrations (which block
// startup on failure) and wires the combined Postgres+Redis store via
// backend/store.NewStore. Without them it runs a dev-only in-memory
// fallback that loses all state on restart and must never serve
// production traffic.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/calcar/calcar/backend/api"
	"github.com/calcar/calcar/backend/store"
	"github.com/calcar/calcar/backend/store/postgres"
	"github.com/calcar/calcar/backend/store/redis"
)

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func main() {
	port := envOr("PORT", "8080")
	pgDSN := strings.TrimSpace(os.Getenv("PG_DSN"))
	redisAddr := strings.TrimSpace(os.Getenv("REDIS_ADDR"))

	st := openStore(pgDSN, redisAddr)

	srv := api.NewServer(st)
	if raw := strings.TrimSpace(os.Getenv("TOKEN_TTL")); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			log.Fatalf("calcar-api: bad TOKEN_TTL %q: %v", raw, err)
		}
		srv.TokenTTL = d
	}
	srv.Hub().Go()
	defer srv.Hub().Close()

	// Migrations run before API start and block deploy on failure (P3).
	// No migrations exist yet; the combined store constructor must run
	// them (or document their runner) when it lands.

	httpSrv := &http.Server{
		Addr:              ":" + port,
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Printf("calcar-api: listening on :%s", port)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("calcar-api: %v", err)
	}
}

// openStore wires the combined Postgres+Redis seam. Migrations run
// before the pool opens and block startup on failure (P3 ops rule).
// Without PG_DSN and REDIS_ADDR it falls back to the dev-only
// in-memory store below.
func openStore(pgDSN, redisAddr string) store.Store {
	if pgDSN == "" || redisAddr == "" {
		log.Printf("calcar-api: PG_DSN/REDIS_ADDR unset; dev-only in-memory store (no persistence)")
		return newMemStore()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := postgres.Migrate(ctx, pgDSN); err != nil {
		log.Fatalf("calcar-api: migrate: %v", err)
	}
	pg, err := postgres.NewStore(ctx, pgDSN)
	if err != nil {
		log.Fatalf("calcar-api: postgres: %v", err)
	}
	rd, err := redis.NewStore(ctx, redisAddr)
	if err != nil {
		log.Fatalf("calcar-api: redis: %v", err)
	}
	log.Printf("calcar-api: combined postgres+redis store")
	return store.NewStore(pg, rd)
}

// ---- dev-only in-memory fallback (no persistence, never production) ----

var _ store.Store = (*memStore)(nil)

type memChallenge struct {
	value string
	exp   time.Time
}

type memToken struct {
	deviceID string
	userID   string
	exp      time.Time
}

type memStore struct {
	mu         sync.Mutex
	users      int
	devices    map[string]store.Device
	sessions   map[string]store.PairingSession
	grants     []store.TrustGrant
	challenges map[string]memChallenge
	tokens     map[string]memToken
	presence   map[string]store.Presence
	seen       map[string]time.Time
	revokedBy  map[string]string
}

func newMemStore() *memStore {
	return &memStore{
		devices:    make(map[string]store.Device),
		sessions:   make(map[string]store.PairingSession),
		challenges: make(map[string]memChallenge),
		tokens:     make(map[string]memToken),
		presence:   make(map[string]store.Presence),
		seen:       make(map[string]time.Time),
		revokedBy:  make(map[string]string),
	}
}

func memRand(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (m *memStore) CreateUser(_ context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.users++
	return "user-" + itoa(m.users) + "-" + memRand(6), nil
}

func (m *memStore) RegisterDevice(_ context.Context, d store.Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, dup := m.devices[d.ID]; dup {
		return store.ErrConflict
	}
	m.devices[d.ID] = d
	return nil
}

func (m *memStore) GetDevice(_ context.Context, id string) (store.Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return store.Device{}, store.ErrNotFound
	}
	return d, nil
}

func (m *memStore) ListUserDevices(_ context.Context, userID string) ([]store.Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.Device
	for _, d := range m.devices {
		if d.UserID == userID {
			out = append(out, d)
		}
	}
	return out, nil
}

func (m *memStore) RevokeDevice(_ context.Context, id, revokedBy, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return store.ErrNotFound
	}
	d.Revoked = true
	m.devices[id] = d
	m.revokedBy[id] = revokedBy
	return nil
}

func (m *memStore) IsRevoked(_ context.Context, deviceID string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[deviceID]
	if !ok {
		return false, store.ErrNotFound
	}
	return d.Revoked, nil
}

func (m *memStore) CreatePairingSession(_ context.Context, s store.PairingSession) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, dup := m.sessions[s.ID]; dup {
		return store.ErrConflict
	}
	s.Status = store.SessionPending
	m.sessions[s.ID] = s
	return nil
}

func (m *memStore) GetPairingSession(_ context.Context, id string) (store.PairingSession, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok {
		return store.PairingSession{}, store.ErrNotFound
	}
	return s, nil
}

func (m *memStore) SubmitJoinRequest(_ context.Context, sessionID string, pubKey []byte, fingerprint, displayName, requestID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[sessionID]
	if !ok {
		return store.ErrNotFound
	}
	if time.Now().After(s.ExpiresAt) {
		s.Status = store.SessionExpired
		m.sessions[sessionID] = s
		return store.ErrExpired
	}
	if s.Status != store.SessionPending || s.JoinRequestID != "" {
		return store.ErrGone
	}
	s.JoinPubKey = append([]byte(nil), pubKey...)
	s.JoinFingerprint = fingerprint
	s.JoinName = displayName
	s.JoinRequestID = requestID
	m.sessions[sessionID] = s
	return nil
}

func (m *memStore) DecidePairingSession(_ context.Context, sessionID string, approve bool, subjectPubKey, _ []byte, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[sessionID]
	if !ok {
		return store.ErrNotFound
	}
	if time.Now().After(s.ExpiresAt) {
		s.Status = store.SessionExpired
		m.sessions[sessionID] = s
		return store.ErrExpired
	}
	if s.Status != store.SessionPending {
		return store.ErrGone
	}
	if s.JoinRequestID == "" {
		return store.ErrConflict
	}
	if approve && string(subjectPubKey) != string(s.JoinPubKey) {
		return store.ErrForbidden
	}
	if approve {
		s.Status = store.SessionApproved
	} else {
		s.Status = store.SessionRejected
	}
	m.sessions[sessionID] = s
	return nil
}

func (m *memStore) RecordGrant(_ context.Context, g store.TrustGrant) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.grants = append(m.grants, g)
	return nil
}

func (m *memStore) IssueChallenge(_ context.Context, deviceID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.devices[deviceID]; !ok {
		return "", store.ErrNotFound
	}
	ch := "ch-" + memRand(18)
	m.challenges[deviceID] = memChallenge{value: ch, exp: time.Now().Add(2 * time.Minute)}
	return ch, nil
}

func (m *memStore) ConsumeChallenge(_ context.Context, deviceID, challenge string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.challenges[deviceID]
	if !ok || c.value != challenge || time.Now().After(c.exp) {
		return store.ErrNotFound
	}
	delete(m.challenges, deviceID)
	return nil
}

func (m *memStore) IssueAccessToken(_ context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	tok := "tok-" + memRand(24)
	m.tokens[tok] = memToken{deviceID: deviceID, userID: userID, exp: time.Now().Add(ttl)}
	return tok, nil
}

func (m *memStore) ResolveAccessToken(_ context.Context, token string) (string, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[token]
	if !ok || time.Now().After(t.exp) {
		return "", "", store.ErrNotFound
	}
	return t.deviceID, t.userID, nil
}

func (m *memStore) RevokeDeviceTokens(_ context.Context, deviceID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for tok, t := range m.tokens {
		if t.deviceID == deviceID {
			delete(m.tokens, tok)
		}
	}
	return nil
}

func (m *memStore) SetPresence(_ context.Context, p store.Presence) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.presence[p.DeviceID] = p
	return nil
}

func (m *memStore) GetPresence(_ context.Context, deviceID string) (store.Presence, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.presence[deviceID]
	if !ok {
		return store.Presence{}, store.ErrNotFound
	}
	return p, nil
}

func (m *memStore) SetPushToken(_ context.Context, _, _, _ string) error {
	return nil
}

func (m *memStore) EnqueueAttention(_ context.Context, _ string, _ store.Attention) error {
	return nil
}

func (m *memStore) CheckAndMarkRequest(_ context.Context, requestID string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	for id, exp := range m.seen {
		if !now.Before(exp) {
			delete(m.seen, id)
		}
	}
	if exp, dup := m.seen[requestID]; dup && now.Before(exp) {
		return store.ErrReplayed
	}
	m.seen[requestID] = now.Add(ttl)
	return nil
}

func (m *memStore) Ping(_ context.Context) error { return nil }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
