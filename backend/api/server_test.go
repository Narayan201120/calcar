package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/calcar/calcar/backend/store"
	"github.com/calcar/calcar/backend/trust"

	calcarv1 "github.com/calcar/calcar/backend/gen/calcar/v1"
)

var _ store.Store = (*fakeStore)(nil)

// fakeStore is an in-memory store.Store for httptest. FailPing flips
// readyz; everything else follows the seam contracts.
type fakeStore struct {
	mu         sync.Mutex
	users      int
	devices    map[string]store.Device
	sessions   map[string]store.PairingSession
	challenges map[string]challRec
	tokens     map[string]tokRec
	presence   map[string]store.Presence
	seen       map[string]time.Time
	calls      []string
	FailPing   bool
}

func (f *fakeStore) noteCall(c string) {
	f.calls = append(f.calls, c)
}

type challRec struct {
	value string
	exp   time.Time
}
type tokRec struct {
	deviceID string
	userID   string
	exp      time.Time
}

func newFake() *fakeStore {
	return &fakeStore{
		devices:    make(map[string]store.Device),
		sessions:   make(map[string]store.PairingSession),
		challenges: make(map[string]challRec),
		tokens:     make(map[string]tokRec),
		presence:   make(map[string]store.Presence),
		seen:       make(map[string]time.Time),
	}
}

func newTestServer() (*Server, *fakeStore) {
	f := newFake()
	return NewServer(f), f
}

func (f *fakeStore) CreateUser(_ context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.users++
	return fmt.Sprintf("user-%d", f.users), nil
}

func (f *fakeStore) RegisterDevice(_ context.Context, d store.Device) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.noteCall("register:" + d.ID)
	if _, dup := f.devices[d.ID]; dup {
		return store.ErrConflict
	}
	f.devices[d.ID] = d
	return nil
}

func (f *fakeStore) GetDevice(_ context.Context, id string) (store.Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.devices[id]
	if !ok {
		return store.Device{}, store.ErrNotFound
	}
	return d, nil
}

func (f *fakeStore) ListUserDevices(_ context.Context, userID string) ([]store.Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []store.Device
	for _, d := range f.devices {
		if d.UserID == userID {
			out = append(out, d)
		}
	}
	return out, nil
}

func (f *fakeStore) RevokeDevice(_ context.Context, id, _, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.devices[id]
	if !ok {
		return store.ErrNotFound
	}
	d.Revoked = true
	f.devices[id] = d
	return nil
}

func (f *fakeStore) IsRevoked(_ context.Context, deviceID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.devices[deviceID]
	if !ok {
		return false, store.ErrNotFound
	}
	return d.Revoked, nil
}

func (f *fakeStore) CreatePairingSession(_ context.Context, s store.PairingSession) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, dup := f.sessions[s.ID]; dup {
		return store.ErrConflict
	}
	f.sessions[s.ID] = s
	return nil
}

func (f *fakeStore) GetPairingSession(_ context.Context, id string) (store.PairingSession, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	s, ok := f.sessions[id]
	if !ok {
		return store.PairingSession{}, store.ErrNotFound
	}
	return s, nil
}

func (f *fakeStore) SubmitJoinRequest(_ context.Context, sessionID string, pubKey []byte, fingerprint, displayName, requestID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	s, ok := f.sessions[sessionID]
	if !ok {
		return store.ErrNotFound
	}
	if time.Now().After(s.ExpiresAt) {
		s.Status = store.SessionExpired
		f.sessions[sessionID] = s
		return store.ErrExpired
	}
	if s.Status != store.SessionPending || s.JoinRequestID != "" {
		return store.ErrGone
	}
	s.JoinPubKey = append([]byte(nil), pubKey...)
	s.JoinFingerprint = fingerprint
	s.JoinName = displayName
	s.JoinRequestID = requestID
	f.sessions[sessionID] = s
	return nil
}

func (f *fakeStore) DecidePairingSession(_ context.Context, sessionID string, approve bool, subjectPubKey, _ []byte, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.noteCall("decide:" + sessionID)
	s, ok := f.sessions[sessionID]
	if !ok {
		return store.ErrNotFound
	}
	if time.Now().After(s.ExpiresAt) {
		s.Status = store.SessionExpired
		f.sessions[sessionID] = s
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
	f.sessions[sessionID] = s
	return nil
}

func (f *fakeStore) RecordGrant(_ context.Context, _ store.TrustGrant) error { return nil }

func (f *fakeStore) IssueChallenge(_ context.Context, deviceID string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.devices[deviceID]; !ok {
		return "", store.ErrNotFound
	}
	b := make([]byte, 18)
	_, _ = rand.Read(b)
	ch := "ch-" + base64.RawURLEncoding.EncodeToString(b)
	f.challenges[deviceID] = challRec{value: ch, exp: time.Now().Add(2 * time.Minute)}
	return ch, nil
}

func (f *fakeStore) ConsumeChallenge(_ context.Context, deviceID, challenge string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	c, ok := f.challenges[deviceID]
	if !ok || c.value != challenge || time.Now().After(c.exp) {
		return store.ErrNotFound
	}
	delete(f.challenges, deviceID)
	return nil
}

func (f *fakeStore) IssueAccessToken(_ context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	tok := "tok-" + base64.RawURLEncoding.EncodeToString(b)
	f.tokens[tok] = tokRec{deviceID: deviceID, userID: userID, exp: time.Now().Add(ttl)}
	return tok, nil
}

func (f *fakeStore) ResolveAccessToken(_ context.Context, token string) (string, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	t, ok := f.tokens[token]
	if !ok || time.Now().After(t.exp) {
		return "", "", store.ErrNotFound
	}
	return t.deviceID, t.userID, nil
}

func (f *fakeStore) RevokeDeviceTokens(_ context.Context, deviceID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for tok, t := range f.tokens {
		if t.deviceID == deviceID {
			delete(f.tokens, tok)
		}
	}
	return nil
}

func (f *fakeStore) SetPresence(_ context.Context, p store.Presence) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.presence[p.DeviceID] = p
	return nil
}

func (f *fakeStore) GetPresence(_ context.Context, deviceID string) (store.Presence, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p, ok := f.presence[deviceID]
	if !ok {
		return store.Presence{}, store.ErrNotFound
	}
	return p, nil
}

func (f *fakeStore) SetPushToken(_ context.Context, _, _, _ string) error { return nil }
func (f *fakeStore) EnqueueAttention(_ context.Context, _ string, _ store.Attention) error {
	return nil
}

func (f *fakeStore) CheckAndMarkRequest(_ context.Context, requestID string, ttl time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	now := time.Now()
	for id, exp := range f.seen {
		if !now.Before(exp) {
			delete(f.seen, id)
		}
	}
	if exp, dup := f.seen[requestID]; dup && now.Before(exp) {
		return store.ErrReplayed
	}
	f.seen[requestID] = now.Add(ttl)
	return nil
}

func (f *fakeStore) Ping(_ context.Context) error {
	if f.FailPing {
		return context.DeadlineExceeded
	}
	return nil
}

// ---- HTTP test helpers ----

var ridSeq atomic.Int64

func freshRID() string { return fmt.Sprintf("rid-%d-%d", time.Now().UnixNano(), ridSeq.Add(1)) }

func doReq(t *testing.T, srv *Server, method, path string, body any, token, rid string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if rid != "" {
		req.Header.Set("X-Request-ID", rid)
	}
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)
	return rec
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("bad JSON %q: %v", rec.Body.String(), err)
	}
	return m
}

func newKeypair(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// bootstrapOwner registers the first Owner phone; returns user, device, keys.
func bootstrapOwner(t *testing.T, srv *Server, name string) (string, string, ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv := newKeypair(t)
	rec := doReq(t, srv, "POST", "/v1/users/bootstrap", map[string]any{
		"display_name": name, "pubkey_b64": b64(pub),
	}, "", freshRID())
	if rec.Code != http.StatusCreated {
		t.Fatalf("bootstrap = %d %s", rec.Code, rec.Body.String())
	}
	m := decodeBody(t, rec)
	return m["user_id"].(string), m["device_id"].(string), pub, priv
}

// authtoken runs challenge+verify for a device.
func authtoken(t *testing.T, srv *Server, deviceID string, priv ed25519.PrivateKey) string {
	t.Helper()
	rec := doReq(t, srv, "POST", "/v1/auth/challenge", map[string]any{"device_id": deviceID}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("challenge = %d %s", rec.Code, rec.Body.String())
	}
	ch := decodeBody(t, rec)["challenge"].(string)
	sig := ed25519.Sign(priv, []byte(ch))
	rec = doReq(t, srv, "POST", "/v1/auth/verify", map[string]any{
		"device_id": deviceID, "challenge": ch, "signature_b64": b64(sig),
	}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("verify = %d %s", rec.Code, rec.Body.String())
	}
	return decodeBody(t, rec)["access_token"].(string)
}

func createSession(t *testing.T, srv *Server, token string) map[string]any {
	t.Helper()
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions", map[string]any{}, token, freshRID())
	if rec.Code != http.StatusCreated {
		t.Fatalf("create session = %d %s", rec.Code, rec.Body.String())
	}
	return decodeBody(t, rec)
}

func joinSession(t *testing.T, srv *Server, sessionID, nonce string, pub ed25519.PublicKey, name string) (string, string) {
	t.Helper()
	fp, err := trust.FingerprintEd25519Pub(pub)
	if err != nil {
		t.Fatal(err)
	}
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/"+sessionID+"/join-request", map[string]any{
		"pubkey_b64": b64(pub), "fingerprint": fp,
		"display_name": name, "request_id": freshRID(), "qr_nonce": nonce,
	}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("join = %d %s", rec.Code, rec.Body.String())
	}
	return fp, name
}

// ownerApprove builds the Owner-signed AuthorizationRecord exactly as a
// phone must: server bindings + phone-chosen id/nonce/time, context
// hash over the join event values with the creation-proxy timestamp.
func ownerApprove(t *testing.T, srv *Server, token, sessionID string, ownerID string, ownerPriv ed25519.PrivateKey, subjectPub ed25519.PublicKey, joinName, joinFP string) *httptest.ResponseRecorder {
	t.Helper()
	grec := doReq(t, srv, "GET", "/v1/pairing/sessions/"+sessionID, nil, token, "")
	if grec.Code != http.StatusOK {
		t.Fatalf("get session = %d %s", grec.Code, grec.Body.String())
	}
	gsess := decodeBody(t, grec)
	expires := int64(gsess["expires_at_millis"].(float64))
	requestedAt := expires - trust.PairingTTLMillis
	subjectDeviceID, err := trust.DeviceIDForComputer(subjectPub)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	rec := &calcarv1.AuthorizationRecord{
		AuthorizationId:  "auth-" + freshRID(),
		SessionId:        sessionID,
		SubjectDeviceId:  &calcarv1.DeviceId{Value: subjectDeviceID},
		SubjectPublicKey: subjectPub,
		OwnerDeviceId:    &calcarv1.DeviceId{Value: ownerID},
		ContextHash:      trust.ContextHash(joinName, joinFP, subjectDeviceID, sessionID, requestedAt),
		DecidedAtMillis:  time.Now().UnixMilli(),
		Nonce:            nonce,
	}
	// Test-only signer: allowed in tests, forbidden in non-test code.
	if _, err := trust.SignAuthorizationForTest(ownerPriv, rec); err != nil {
		t.Fatal(err)
	}
	return doReq(t, srv, "POST", "/v1/pairing/sessions/"+sessionID+"/decision", map[string]any{
		"approve": true, "subject_pubkey_b64": b64(subjectPub),
		"signature_b64": b64(rec.OwnerSignature), "authorization_id": rec.AuthorizationId,
		"nonce_b64": b64(nonce), "decided_at_millis": rec.DecidedAtMillis,
	}, token, freshRID())
}

// ---- tests ----

func TestHealthzReadyz(t *testing.T) {
	srv, f := newTestServer()
	if rec := doReq(t, srv, "GET", "/healthz", nil, "", ""); rec.Code != http.StatusOK {
		t.Fatalf("healthz = %d", rec.Code)
	}
	if rec := doReq(t, srv, "GET", "/readyz", nil, "", ""); rec.Code != http.StatusOK {
		t.Fatalf("readyz = %d", rec.Code)
	}
	f.FailPing = true
	if rec := doReq(t, srv, "GET", "/readyz", nil, "", ""); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz sick = %d, want 503", rec.Code)
	}
}

func TestPairingHappyPath(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner Phone")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)

	sess := createSession(t, srv, ownerTok)
	sessionID := sess["session_id"].(string)
	if sess["qr_nonce"] == "" || sess["expires_at_millis"] == nil {
		t.Fatalf("session missing qr fields: %v", sess)
	}

	compPub, compPriv := newKeypair(t)
	joinFP, joinName := joinSession(t, srv, sessionID, sess["qr_nonce"].(string), compPub, "DESK-01")

	dec := ownerApprove(t, srv, ownerTok, sessionID, ownerID, ownerPriv, compPub, joinName, joinFP)
	if dec.Code != http.StatusOK {
		t.Fatalf("decision = %d %s", dec.Code, dec.Body.String())
	}
	dm := decodeBody(t, dec)
	subjectID, _ := trust.DeviceIDForComputer(compPub)
	if dm["status"] != store.SessionApproved || dm["subject_device_id"] != subjectID {
		t.Fatalf("decision body = %v", dm)
	}

	// Trust graph shows owner + computer.
	rec := doReq(t, srv, "GET", "/v1/trust/graph", nil, ownerTok, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("graph = %d", rec.Code)
	}
	devs := decodeBody(t, rec)["devices"].([]any)
	if len(devs) != 2 {
		t.Fatalf("graph devices = %d, want 2", len(devs))
	}

	// Approved computer completes challenge auth and lists devices.
	compTok := authtoken(t, srv, subjectID, compPriv)
	rec = doReq(t, srv, "GET", "/v1/devices", nil, compTok, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("computer list = %d %s", rec.Code, rec.Body.String())
	}

	// Computer posts attention + heartbeat; owner reads presence.
	rec = doReq(t, srv, "POST", "/v1/notify/attention", map[string]any{
		"computer_id": subjectID, "workflow_id": "wf-1", "kind": "approval_required",
	}, compTok, freshRID())
	if rec.Code != http.StatusAccepted {
		t.Fatalf("attention = %d %s", rec.Code, rec.Body.String())
	}
	rec = doReq(t, srv, "POST", "/v1/presence/heartbeat", map[string]any{"online": true}, compTok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("heartbeat = %d %s", rec.Code, rec.Body.String())
	}
	rec = doReq(t, srv, "GET", "/v1/computers/"+subjectID+"/presence", nil, ownerTok, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("presence = %d %s", rec.Code, rec.Body.String())
	}
	if !decodeBody(t, rec)["online"].(bool) {
		t.Fatal("presence online = false, want true")
	}

	// Reject path on a fresh session.
	sess2 := createSession(t, srv, ownerTok)
	sid2 := sess2["session_id"].(string)
	p2, _ := newKeypair(t)
	joinSession(t, srv, sid2, sess2["qr_nonce"].(string), p2, "DESK-02")
	rec = doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid2+"/decision", map[string]any{
		"approve": false, "subject_pubkey_b64": b64(p2),
	}, ownerTok, freshRID())
	if rec.Code != http.StatusOK || decodeBody(t, rec)["status"] != store.SessionRejected {
		t.Fatalf("reject = %d %s", rec.Code, rec.Body.String())
	}
}

func TestPairingExpiredJoin410(t *testing.T) {
	srv, f := newFakeServer(t)
	expired := store.PairingSession{
		ID: "sess-expired", UserID: "user-9", CreatedBy: "PH-1",
		Status: store.SessionPending, ExpiresAt: time.Now().Add(-time.Minute),
		QRNonce: "n",
	}
	f.mu.Lock()
	f.sessions[expired.ID] = expired
	f.mu.Unlock()
	pub, _ := newKeypair(t)
	fp, _ := trust.FingerprintEd25519Pub(pub)
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/sess-expired/join-request", map[string]any{
		"pubkey_b64": b64(pub), "fingerprint": fp,
		"display_name": "PC", "request_id": freshRID(),
	}, "", "")
	if rec.Code != http.StatusGone {
		t.Fatalf("expired join = %d, want 410", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodePairingExpired {
		t.Fatalf("expired join code = %s", rec.Body.String())
	}
}

func TestPairingJoinUnknown404(t *testing.T) {
	srv, _ := newTestServer()
	pub, _ := newKeypair(t)
	fp, _ := trust.FingerprintEd25519Pub(pub)
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/nope/join-request", map[string]any{
		"pubkey_b64": b64(pub), "fingerprint": fp,
		"display_name": "PC", "request_id": freshRID(),
	}, "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown join = %d, want 404", rec.Code)
	}
}

func TestPairingJoinWrongNonce422(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, tok)
	sid := sess["session_id"].(string)
	pub, _ := newKeypair(t)
	fp, _ := trust.FingerprintEd25519Pub(pub)
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid+"/join-request", map[string]any{
		"pubkey_b64": b64(pub), "fingerprint": fp,
		"display_name": "PC", "request_id": freshRID(), "qr_nonce": "wrong-nonce",
	}, "", "")
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("wrong nonce join = %d, want 422", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodeQRMismatch {
		t.Fatalf("wrong nonce code = %s", rec.Body.String())
	}
	// Wrong nonce burns nothing: the real QR still joins.
	joinSession(t, srv, sid, sess["qr_nonce"].(string), pub, "PC")
}

func TestPairingJoinMissingNonce400(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, tok)
	sid := sess["session_id"].(string)
	pub, _ := newKeypair(t)
	fp, _ := trust.FingerprintEd25519Pub(pub)
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid+"/join-request", map[string]any{
		"pubkey_b64": b64(pub), "fingerprint": fp,
		"display_name": "PC", "request_id": freshRID(),
	}, "", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("missing nonce join = %d, want 400", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodeInvalidInput {
		t.Fatalf("missing nonce code = %s", rec.Body.String())
	}
}

func TestApproveRegistersBeforeDecide(t *testing.T) {
	srv, f := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, tok)
	sid := sess["session_id"].(string)
	cp, _ := newKeypair(t)
	fp, name := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	if dec := ownerApprove(t, srv, tok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusOK {
		t.Fatalf("approve = %d %s", dec.Code, dec.Body.String())
	}
	subjectID, _ := trust.DeviceIDForComputer(cp)
	f.mu.Lock()
	defer f.mu.Unlock()
	regIdx, decIdx := -1, -1
	for i, c := range f.calls {
		if c == "register:"+subjectID {
			regIdx = i
		}
		if c == "decide:"+sid {
			decIdx = i
		}
	}
	if regIdx < 0 {
		t.Fatalf("computer was never registered, calls = %v", f.calls)
	}
	if decIdx < 0 {
		t.Fatalf("session was never decided, calls = %v", f.calls)
	}
	if regIdx > decIdx {
		t.Fatalf("register ran after decide: calls = %v", f.calls)
	}
	if _, ok := f.devices[subjectID]; !ok {
		t.Fatalf("computer row missing after approve")
	}
}

func TestPairingDoubleDecide410(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, tok)
	sid := sess["session_id"].(string)
	cp, _ := newKeypair(t)
	fp, name := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	if dec := ownerApprove(t, srv, tok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusOK {
		t.Fatalf("first decide = %d %s", dec.Code, dec.Body.String())
	}
	// Second decision with a fresh idempotency key still fails: single use.
	if dec := ownerApprove(t, srv, tok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusGone {
		t.Fatalf("double decide = %d, want 410", dec.Code)
	} else if decodeBody(t, dec)["error"] != trust.CodePairingConsumed {
		t.Fatalf("double decide code = %s", dec.Body.String())
	}
}

func TestDecisionWrongPubkey422(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, ownerPub, ownerPriv := bootstrapOwner(t, srv, "Owner")
	_ = ownerPub
	tok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, tok)
	sid := sess["session_id"].(string)
	cp, _ := newKeypair(t)
	joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	other, _ := newKeypair(t)
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid+"/decision", map[string]any{
		"approve": true, "subject_pubkey_b64": b64(other),
		"signature_b64": b64(make([]byte, 64)), "authorization_id": "a",
		"nonce_b64": b64([]byte{1}), "decided_at_millis": time.Now().UnixMilli(),
	}, tok, freshRID())
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("wrong pubkey = %d, want 422", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodePubkeyMismatch {
		t.Fatalf("wrong pubkey code = %s", rec.Body.String())
	}
	// Session stays pending: no grant written, still readable by creator.
	grec := doReq(t, srv, "GET", "/v1/pairing/sessions/"+sid, nil, tok, "")
	if decodeBody(t, grec)["status"] != store.SessionPending {
		t.Fatalf("session after 422 = %s", grec.Body.String())
	}
}

func TestComputerDecision403(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, ownerTok)
	sid := sess["session_id"].(string)
	cp, cpPriv := newKeypair(t)
	fp, name := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	if dec := ownerApprove(t, srv, ownerTok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusOK {
		t.Fatalf("approve = %d", dec.Code)
	}
	subjectID, _ := trust.DeviceIDForComputer(cp)
	compTok := authtoken(t, srv, subjectID, cpPriv)

	sess2 := createSession(t, srv, ownerTok)
	sid2 := sess2["session_id"].(string)
	p2, _ := newKeypair(t)
	joinSession(t, srv, sid2, sess2["qr_nonce"].(string), p2, "PC2")
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid2+"/decision", map[string]any{
		"approve": false, "subject_pubkey_b64": b64(p2),
	}, compTok, freshRID())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("computer decision = %d, want 403", rec.Code)
	}
}

func TestComputerRevoke403(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, ownerTok)
	sid := sess["session_id"].(string)
	cp, cpPriv := newKeypair(t)
	fp, name := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	if dec := ownerApprove(t, srv, ownerTok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusOK {
		t.Fatalf("approve = %d", dec.Code)
	}
	subjectID, _ := trust.DeviceIDForComputer(cp)
	compTok := authtoken(t, srv, subjectID, cpPriv)
	rec := doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/revoke", map[string]any{}, compTok, freshRID())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("computer revoke = %d, want 403", rec.Code)
	}
}

func TestRevokedDevice401(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	sess := createSession(t, srv, ownerTok)
	sid := sess["session_id"].(string)
	cp, cpPriv := newKeypair(t)
	fp, name := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, "PC")
	if dec := ownerApprove(t, srv, ownerTok, sid, ownerID, ownerPriv, cp, name, fp); dec.Code != http.StatusOK {
		t.Fatalf("approve = %d", dec.Code)
	}
	subjectID, _ := trust.DeviceIDForComputer(cp)
	compTok := authtoken(t, srv, subjectID, cpPriv)

	rec := doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/revoke", map[string]any{"reason": "lost"}, ownerTok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke = %d %s", rec.Code, rec.Body.String())
	}
	// Dead token: next call is 401.
	rec = doReq(t, srv, "GET", "/v1/devices", nil, compTok, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked call = %d, want 401", rec.Code)
	}
	// Fresh login refused too: verify fails closed on the revoked record.
	rec = doReq(t, srv, "POST", "/v1/auth/challenge", map[string]any{"device_id": subjectID}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("challenge after revoke = %d", rec.Code)
	}
	ch := decodeBody(t, rec)["challenge"].(string)
	rec = doReq(t, srv, "POST", "/v1/auth/verify", map[string]any{
		"device_id": subjectID, "challenge": ch,
		"signature_b64": b64(ed25519.Sign(cpPriv, []byte(ch))),
	}, "", "")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("verify after revoke = %d, want 403", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodeRevoked {
		t.Fatalf("revoked code = %s", rec.Body.String())
	}
}

func TestReplayedRequestID409(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	rid := freshRID()
	if rec := doReq(t, srv, "POST", "/v1/pairing/sessions", map[string]any{}, tok, rid); rec.Code != http.StatusCreated {
		t.Fatalf("first create = %d", rec.Code)
	}
	rec := doReq(t, srv, "POST", "/v1/pairing/sessions", map[string]any{}, tok, rid)
	if rec.Code != http.StatusConflict {
		t.Fatalf("replayed rid = %d, want 409", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodeReplayedID {
		t.Fatalf("replay code = %s", rec.Body.String())
	}
	// Missing key is 400.
	if rec := doReq(t, srv, "POST", "/v1/pairing/sessions", map[string]any{}, tok, ""); rec.Code != http.StatusBadRequest {
		t.Fatalf("missing rid = %d, want 400", rec.Code)
	}
}

func TestRelay501(t *testing.T) {
	srv, _ := newTestServer()
	rec := doReq(t, srv, "POST", "/v1/relay/alloc", map[string]any{}, "", "")
	if rec.Code != http.StatusNotImplemented {
		t.Fatalf("relay = %d, want 501", rec.Code)
	}
	m := decodeBody(t, rec)
	if m["error"] != "relay_not_configured" || m["retryable"] != false || len(m) != 2 {
		t.Fatalf("relay schema = %v", m)
	}
}

func TestSecondOwner403(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	tok := authtoken(t, srv, ownerID, ownerPriv)
	pub2, _ := newKeypair(t)
	rec := doReq(t, srv, "POST", "/v1/devices", map[string]any{
		"device_id": "PH-SECOND", "display_name": "Second",
		"pubkey_b64": b64(pub2), "role": store.RoleOwnerPhone,
	}, tok, freshRID())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("second owner = %d, want 403", rec.Code)
	}
}

func TestDeviceNameUpdateOnly(t *testing.T) {
	srv, f := newFakeServer(t)
	uid, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	_ = ownerID
	tok := authtoken(t, srv, ownerID, ownerPriv)
	pub, _ := newKeypair(t)
	fp, _ := trust.FingerprintEd25519Pub(pub)
	f.mu.Lock()
	f.devices["PH-X"] = store.Device{ID: "PH-X", UserID: uid, Role: store.RoleTrustedPhone, DisplayName: "Old", PubKey: pub, Fingerprint: fp}
	f.mu.Unlock()
	rec := doReq(t, srv, "POST", "/v1/devices", map[string]any{
		"device_id": "PH-X", "display_name": "New",
		"pubkey_b64": b64(pub), "fingerprint": fp,
	}, tok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("rename = %d %s", rec.Code, rec.Body.String())
	}
	other, _ := newKeypair(t)
	rec = doReq(t, srv, "POST", "/v1/devices", map[string]any{
		"device_id": "PH-X", "display_name": "New",
		"pubkey_b64": b64(other),
	}, tok, freshRID())
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("key swap = %d, want 422", rec.Code)
	}
}

func newFakeServer(t *testing.T) (*Server, *fakeStore) {
	t.Helper()
	f := newFake()
	return NewServer(f), f
}
