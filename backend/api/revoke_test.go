package api

// Revocation end-to-end proof (PLAN P7/P8 bar): revoked rejected 100
// percent, propagation proved when online and on reconnect when
// offline. Reuses the httptest helpers in server_test.go.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/calcar/calcar/backend/store"
	"github.com/calcar/calcar/backend/trust"
)

// pairComputer runs the full Owner plus session plus PC join plus
// approve loop and returns the computer ids, keys, and live tokens.
func pairComputer(t *testing.T, srv *Server, ownerTok, ownerID string, ownerPriv ed25519.PrivateKey, name string) (string, ed25519.PublicKey, ed25519.PrivateKey, string, string) {
	t.Helper()
	sess := createSession(t, srv, ownerTok)
	sid := sess["session_id"].(string)
	cp, cpPriv := newKeypair(t)
	fp, joinName := joinSession(t, srv, sid, sess["qr_nonce"].(string), cp, name)
	if dec := ownerApprove(t, srv, ownerTok, sid, ownerID, ownerPriv, cp, joinName, fp); dec.Code != http.StatusOK {
		t.Fatalf("approve %s = %d %s", name, dec.Code, dec.Body.String())
	}
	subjectID, err := trust.DeviceIDForComputer(cp)
	if err != nil {
		t.Fatal(err)
	}
	acc, rfr := verifyPair(t, srv, subjectID, cpPriv)
	return subjectID, cp, cpPriv, acc, rfr
}

// revokedCode asserts a fail-closed 401-or-403 with the REVOKED code
// and no token or device material leaked into the body.
func revokedCode(t *testing.T, what string, rec *httptest.ResponseRecorder, secrets ...string) {
	t.Helper()
	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("%s = %d, want 401 or 403 (body %s)", what, rec.Code, rec.Body.String())
	}
	if got := decodeBody(t, rec)["error"]; got != trust.CodeRevoked {
		t.Fatalf("%s error = %v, want %s (body %s)", what, got, trust.CodeRevoked, rec.Body.String())
	}
	for _, s := range secrets {
		if s != "" && bytes.Contains(rec.Body.Bytes(), []byte(s)) {
			t.Fatalf("%s leaks secret in body %s", what, rec.Body.String())
		}
	}
}

// Only the active Owner phone revokes (pairing spec section 10).
// A trusted phone caller fails closed with 403 NOT_OWNER and the
// victim stays usable.
func TestTrustedPhoneRevokeForbidden(t *testing.T) {
	srv, f := newTestServer()
	uid, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)

	phonePub, phonePriv := newKeypair(t)
	phoneFP, err := trust.FingerprintEd25519Pub(phonePub)
	if err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	f.devices["PH-TRUSTED"] = store.Device{ID: "PH-TRUSTED", UserID: uid, Role: store.RoleTrustedPhone, DisplayName: "Trusted", PubKey: phonePub, Fingerprint: phoneFP}
	compPub, _ := newKeypair(t)
	compFP, err := trust.FingerprintEd25519Pub(compPub)
	if err != nil {
		t.Fatal(err)
	}
	compID, err := trust.DeviceIDForComputer(compPub)
	if err != nil {
		t.Fatal(err)
	}
	f.devices[compID] = store.Device{ID: compID, UserID: uid, Role: store.RoleComputer, DisplayName: "PC", PubKey: compPub, Fingerprint: compFP}
	f.mu.Unlock()
	phoneTok := authtoken(t, srv, "PH-TRUSTED", phonePriv)

	rec := doReq(t, srv, "POST", "/v1/devices/"+compID+"/revoke", map[string]any{"reason": "lost"}, phoneTok, freshRID())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("trusted-phone revoke = %d, want 403", rec.Code)
	}
	if decodeBody(t, rec)["error"] != trust.CodeNotOwner {
		t.Fatalf("trusted-phone revoke code = %s", rec.Body.String())
	}
	// Victim untouched: still listed unrevoked.
	rec = doReq(t, srv, "GET", "/v1/devices", nil, ownerTok, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("devices = %d %s", rec.Code, rec.Body.String())
	}
	for _, d := range decodeBody(t, rec)["devices"].([]any) {
		if d.(map[string]any)["device_id"] == compID && d.(map[string]any)["revoked"] == true {
			t.Fatal("victim revoked by a trusted phone")
		}
	}
}

// A pre-revoke computer token fails on every authed surface after the
// Owner revokes it: heartbeat, devices, trust graph, pairing create,
// presence get, push-token, pairing decision, attention, refresh, and
// fresh challenge+verify. The Owner token keeps working and the
// revoked row stays visible with revoked=true.
func TestRevokedTokenRejectedAllSurfaces(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	subjectID, compPub, compPriv, compTok, compRfr := pairComputer(t, srv, ownerTok, ownerID, ownerPriv, "DESK-01")

	// Live before revoke: heartbeat proves the token works.
	if rec := doReq(t, srv, "POST", "/v1/presence/heartbeat", map[string]any{"online": true}, compTok, freshRID()); rec.Code != http.StatusOK {
		t.Fatalf("pre-revoke heartbeat = %d %s", rec.Code, rec.Body.String())
	}

	rec := doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/revoke", map[string]any{"reason": "lost"}, ownerTok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke = %d %s", rec.Code, rec.Body.String())
	}

	revokedCode(t, "heartbeat", doReq(t, srv, "POST", "/v1/presence/heartbeat", map[string]any{"online": true}, compTok, freshRID()), compTok)
	revokedCode(t, "devices", doReq(t, srv, "GET", "/v1/devices", nil, compTok, ""), compTok)
	revokedCode(t, "trust graph", doReq(t, srv, "GET", "/v1/trust/graph", nil, compTok, ""), compTok)
	revokedCode(t, "pairing create", doReq(t, srv, "POST", "/v1/pairing/sessions", map[string]any{}, compTok, freshRID()), compTok)
	revokedCode(t, "presence get", doReq(t, srv, "GET", "/v1/computers/"+subjectID+"/presence", nil, compTok, ""), compTok)
	revokedCode(t, "push-token", doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/push-token",
		map[string]any{"platform": "fcm", "push_token": "push-1"}, compTok, freshRID()), compTok, "push-1")
	revokedCode(t, "attention", doReq(t, srv, "POST", "/v1/notify/attention",
		map[string]any{"computer_id": subjectID, "workflow_id": "wf-1", "kind": "approval_required"}, compTok, freshRID()), compTok)

	// Decision surface: fresh Owner session, revoked computer attempts
	// the decision. Auth runs first, so the revoked token dies closed
	// even though the body is otherwise well formed.
	sess := createSession(t, srv, ownerTok)
	sid := sess["session_id"].(string)
	p2, _ := newKeypair(t)
	joinSession(t, srv, sid, sess["qr_nonce"].(string), p2, "DESK-02")
	revokedCode(t, "decision", doReq(t, srv, "POST", "/v1/pairing/sessions/"+sid+"/decision",
		map[string]any{"approve": false, "subject_pubkey_b64": b64(p2)}, compTok, freshRID()), compTok)

	// Refresh with the pre-revoke refresh token dies closed.
	rrec := refreshCall(t, srv, subjectID, compRfr, freshRID())
	revokedCode(t, "refresh", rrec, compRfr)

	// Fresh login refused: challenge mints, verify fails closed.
	rec = doReq(t, srv, "POST", "/v1/auth/challenge", map[string]any{"device_id": subjectID}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("challenge after revoke = %d", rec.Code)
	}
	ch := decodeBody(t, rec)["challenge"].(string)
	revokedCode(t, "verify", doReq(t, srv, "POST", "/v1/auth/verify", map[string]any{
		"device_id": subjectID, "challenge": ch,
		"signature_b64": b64(ed25519.Sign(compPriv, []byte(ch))),
	}, "", ""))

	// Owner unaffected: lists devices, sees the revoked row flagged.
	rec = doReq(t, srv, "GET", "/v1/devices", nil, ownerTok, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("owner devices after revoke = %d %s", rec.Code, rec.Body.String())
	}
	seen := false
	for _, d := range decodeBody(t, rec)["devices"].([]any) {
		m := d.(map[string]any)
		if m["device_id"] == subjectID {
			seen = true
			if m["revoked"] != true {
				t.Fatalf("revoked row not flagged: %v", m)
			}
		}
	}
	if !seen {
		t.Fatal("revoked row missing from owner device list")
	}
	_ = compPub
}

// Online propagation: an Owner with a live WS gets trust.revoked the
// moment the computer is revoked, and the revoked token can never
// open a new socket.
func TestRevokeOnlinePropagation(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	subjectID, _, _, compTok, _ := pairComputer(t, srv, ownerTok, ownerID, ownerPriv, "DESK-01")

	srv.Hub().Go()
	defer srv.Hub().Close()
	httpSrv := httptest.NewServer(srv)
	defer httpSrv.Close()
	wsURL := "ws" + strings.TrimPrefix(httpSrv.URL, "http") + "/v1/ws"

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ownerConn, _, err := websocket.Dial(ctx, wsURL+"?access_token="+ownerTok, nil)
	if err != nil {
		t.Fatalf("owner WS dial: %v", err)
	}
	defer func() { _ = ownerConn.Close(websocket.StatusNormalClosure, "test done") }()
	deadline := time.Now().Add(5 * time.Second)
	for srv.Hub().ConnCount() != 1 {
		if time.Now().After(deadline) {
			t.Fatal("owner WS never registered")
		}
		time.Sleep(10 * time.Millisecond)
	}

	rec := doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/revoke", map[string]any{"reason": "lost"}, ownerTok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke = %d %s", rec.Code, rec.Body.String())
	}

	// Owner conn receives trust.revoked naming the subject.
	got := false
	rctx, rcancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer rcancel()
	for !got {
		_, raw, err := ownerConn.Read(rctx)
		if err != nil {
			t.Fatalf("owner WS read: %v", err)
		}
		var env struct {
			Type    string         `json:"type"`
			Payload map[string]any `json:"payload"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("bad envelope: %v", err)
		}
		if env.Type == "trust.revoked" && env.Payload["subject_device_id"] == subjectID {
			got = true
		}
	}
	if !got {
		t.Fatal("trust.revoked never arrived on the live Owner socket")
	}

	// Revoked token opens nothing.
	dctx, dcancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer dcancel()
	if c, resp, err := websocket.Dial(dctx, wsURL+"?access_token="+compTok, nil); err == nil {
		_ = c.Close(websocket.StatusNormalClosure, "should not connect")
		t.Fatal("revoked token WS dial succeeded")
	} else if resp == nil || (resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden) {
		t.Fatalf("revoked WS dial status = %v, want 401/403", resp)
	}
}

// Offline plus reconnect: a computer with no live socket at revoke
// time learns nothing until it tries to come back, and every
// reconnect path then fails closed: WS dial with the pre-revoke
// token, fresh challenge+verify, and heartbeat.
func TestRevokedReconnectRefused(t *testing.T) {
	srv, _ := newTestServer()
	_, ownerID, _, ownerPriv := bootstrapOwner(t, srv, "Owner")
	ownerTok := authtoken(t, srv, ownerID, ownerPriv)
	subjectID, _, compPriv, compTok, _ := pairComputer(t, srv, ownerTok, ownerID, ownerPriv, "DESK-01")

	// Computer stays offline: no WS conn. Owner revokes it unseen.
	rec := doReq(t, srv, "POST", "/v1/devices/"+subjectID+"/revoke", map[string]any{"reason": "lost"}, ownerTok, freshRID())
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke = %d %s", rec.Code, rec.Body.String())
	}

	srv.Hub().Go()
	defer srv.Hub().Close()
	httpSrv := httptest.NewServer(srv)
	defer httpSrv.Close()
	wsURL := "ws" + strings.TrimPrefix(httpSrv.URL, "http") + "/v1/ws"

	dctx, dcancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer dcancel()
	if c, resp, err := websocket.Dial(dctx, wsURL+"?access_token="+compTok, nil); err == nil {
		_ = c.Close(websocket.StatusNormalClosure, "should not connect")
		t.Fatal("offline-revoked WS reconnect succeeded")
	} else if resp == nil || (resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden) {
		t.Fatalf("reconnect WS status = %v, want 401/403", resp)
	}

	rec = doReq(t, srv, "POST", "/v1/auth/challenge", map[string]any{"device_id": subjectID}, "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("challenge after revoke = %d", rec.Code)
	}
	ch := decodeBody(t, rec)["challenge"].(string)
	revokedCode(t, "reconnect verify", doReq(t, srv, "POST", "/v1/auth/verify", map[string]any{
		"device_id": subjectID, "challenge": ch,
		"signature_b64": b64(ed25519.Sign(compPriv, []byte(ch))),
	}, "", ""))
	revokedCode(t, "reconnect heartbeat", doReq(t, srv, "POST", "/v1/presence/heartbeat",
		map[string]any{"online": true}, compTok, freshRID()), compTok)
}
