// Command revoke-e2e is a dev-only revocation prover. It drives a
// dev-only in-memory backend through the full Owner plus session plus
// PC join plus approve loop, revokes the computer as Owner, then
// asserts the pre-revoke token dies on every surface and the live
// Owner socket gets trust.revoked. scripts/e2e-revoke.ps1 drives it.
//
// Approve signing here uses trust.SignAuthorizationForTest exactly
// like backend/api/server_test.go ownerApprove: the harness plays the
// phone, so the test-only signer is acceptable inside this binary.
// Dev only: no product code may import this package.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"nhooyr.io/websocket"

	calcarv1 "github.com/calcar/calcar/backend/gen/calcar/v1"
	"github.com/calcar/calcar/backend/trust"
	"github.com/calcar/calcar/backend/ws"
)

const (
	reqTimeout = 15 * time.Second
	e2eBackend = "http://127.0.0.1:18081"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "revoke FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func pass(format string, args ...any) {
	fmt.Printf("revoke PASS: "+format+"\n", args...)
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func postJSON(client *http.Client, target string, headers map[string]string, body any) (int, []byte) {
	raw, err := json.Marshal(body)
	if err != nil {
		fail("cannot encode request to %s: %v", target, err)
	}
	req, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(raw))
	if err != nil {
		fail("cannot build request to %s: %v", target, err)
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		fail("backend unreachable at %s: %v", target, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, out
}

func getJSON(client *http.Client, target, token string) (int, []byte) {
	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		fail("cannot build request to %s: %v", target, err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		fail("backend unreachable at %s: %v", target, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, out
}

func needCode(what, body string, code, want int) {
	if code != want {
		fail("%s: HTTP %d, want %d: %s", what, code, want, strings.TrimSpace(body))
	}
}

func needClosed(what, body string, code int) {
	if code != http.StatusUnauthorized && code != http.StatusForbidden {
		fail("%s: HTTP %d, want 401 or 403: %s", what, code, strings.TrimSpace(body))
	}
}

func runE2E(client *http.Client, backend, name string) {
	rid := func() string { return "e2e-revoke-" + ws.NewUUIDv4() }
	withAuth := func(tok string) map[string]string {
		return map[string]string{"Authorization": "Bearer " + tok, "X-Request-ID": rid()}
	}

	// 1. Bootstrap Owner.
	ownerPub, ownerPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail("cannot generate Owner key: %v", err)
	}
	code, body := postJSON(client, backend+"/v1/users/bootstrap",
		map[string]string{"X-Request-ID": rid()}, map[string]any{
			"display_name": "E2E Owner",
			"pubkey_b64":   b64(ownerPub),
			"device_id":    "PH-" + strings.ToUpper(ws.NewID()[:8]),
		})
	needCode("bootstrap", string(body), code, http.StatusCreated)
	var boot struct {
		UserID   string `json:"user_id"`
		DeviceID string `json:"device_id"`
	}
	if err := json.Unmarshal(body, &boot); err != nil || boot.DeviceID == "" {
		fail("bootstrap reply unusable: %s", strings.TrimSpace(string(body)))
	}
	pass("bootstrap ok, owner %s", boot.DeviceID)

	// 2. Owner login.
	ownerTok := login(client, backend, boot.DeviceID, ownerPriv)
	pass("owner login ok")

	// 3. Create session, join as PC.
	code, body = postJSON(client, backend+"/v1/pairing/sessions", withAuth(ownerTok), map[string]any{})
	needCode("create session", string(body), code, http.StatusCreated)
	var sess struct {
		SessionID string `json:"session_id"`
		QRNonce   string `json:"qr_nonce"`
	}
	if err := json.Unmarshal(body, &sess); err != nil || sess.SessionID == "" || sess.QRNonce == "" {
		fail("session reply unusable: %s", strings.TrimSpace(string(body)))
	}
	compPub, compPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail("cannot generate PC key: %v", err)
	}
	compFP, err := trust.FingerprintEd25519Pub(compPub)
	if err != nil {
		fail("cannot fingerprint PC key: %v", err)
	}
	code, body = postJSON(client, backend+"/v1/pairing/sessions/"+sess.SessionID+"/join-request", nil, map[string]any{
		"pubkey_b64": b64(compPub), "fingerprint": compFP,
		"display_name": name, "request_id": ws.NewUUIDv4(), "qr_nonce": sess.QRNonce,
	})
	needCode("join", string(body), code, http.StatusOK)
	pass("join landed, card would show %s named %s", compFP, name)

	// 4. Approve as Owner (harness plays the phone; test-only signer
	// acceptable here, same construction as server_test ownerApprove).
	code, body = getJSON(client, backend+"/v1/pairing/sessions/"+sess.SessionID, ownerTok)
	needCode("re-read session", string(body), code, http.StatusOK)
	var gsess struct {
		ExpiresAtMillis int64  `json:"expires_at_millis"`
		JoinFingerprint string `json:"join_fingerprint"`
		JoinDisplayName string `json:"join_display_name"`
	}
	if err := json.Unmarshal(body, &gsess); err != nil {
		fail("session re-read unusable: %s", strings.TrimSpace(string(body)))
	}
	subjectID, err := trust.DeviceIDForComputer(compPub)
	if err != nil {
		fail("cannot derive computer id: %v", err)
	}
	requestedAt := gsess.ExpiresAtMillis - trust.PairingTTLMillis
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		fail("cannot mint nonce: %v", err)
	}
	rec := &calcarv1.AuthorizationRecord{
		AuthorizationId:  "auth-" + ws.NewUUIDv4(),
		SessionId:        sess.SessionID,
		SubjectDeviceId:  &calcarv1.DeviceId{Value: subjectID},
		SubjectPublicKey: compPub,
		OwnerDeviceId:    &calcarv1.DeviceId{Value: boot.DeviceID},
		ContextHash:      trust.ContextHash(gsess.JoinDisplayName, gsess.JoinFingerprint, subjectID, sess.SessionID, requestedAt),
		DecidedAtMillis:  time.Now().UnixMilli(),
		Nonce:            nonce,
	}
	if _, err := trust.SignAuthorizationForTest(ownerPriv, rec); err != nil {
		fail("cannot sign authorization: %v", err)
	}
	code, body = postJSON(client, backend+"/v1/pairing/sessions/"+sess.SessionID+"/decision", withAuth(ownerTok), map[string]any{
		"approve": true, "subject_pubkey_b64": b64(compPub),
		"signature_b64": b64(rec.OwnerSignature), "authorization_id": rec.AuthorizationId,
		"nonce_b64": b64(nonce), "decided_at_millis": rec.DecidedAtMillis,
	})
	needCode("approve", string(body), code, http.StatusOK)
	pass("approve ok, computer %s", subjectID)

	// 5. Computer login: pre-revoke token pair.
	compTok, compRfr := loginPair(client, backend, subjectID, compPriv)
	_ = compRfr
	pass("computer login ok")

	// 6. Live before revoke: heartbeat proves the token works.
	code, body = postJSON(client, backend+"/v1/presence/heartbeat", withAuth(compTok), map[string]any{"online": true})
	needCode("pre-revoke heartbeat", string(body), code, http.StatusOK)
	pass("pre-revoke heartbeat ok")

	// 7. Computer cannot revoke anyone (Owner-only gate).
	code, body = postJSON(client, backend+"/v1/devices/"+boot.DeviceID+"/revoke", withAuth(compTok), map[string]any{"reason": "x"})
	if code != http.StatusForbidden {
		fail("computer revoke attempt: HTTP %d, want 403: %s", code, strings.TrimSpace(string(body)))
	}
	pass("computer revoke refused 403")

	// 8. Owner socket online before the revoke (propagation witness).
	wsBase := strings.Replace(backend, "http://", "ws://", 1)
	wsBase = strings.Replace(wsBase, "https://", "wss://", 1)
	wctx, wcancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer wcancel()
	ownerConn, _, err := websocket.Dial(wctx, wsBase+"/v1/ws?access_token="+ownerTok, nil)
	if err != nil {
		fail("owner WS dial: %v", err)
	}
	defer func() { _ = ownerConn.Close(websocket.StatusNormalClosure, "e2e done") }()
	pass("owner WS online")

	// 9. Owner revokes the computer.
	code, body = postJSON(client, backend+"/v1/devices/"+subjectID+"/revoke", withAuth(ownerTok), map[string]any{"reason": "lost"})
	needCode("revoke", string(body), code, http.StatusOK)
	pass("revoke ok, %s revoked", subjectID)

	// 10. Online propagation: live Owner socket gets trust.revoked.
	rctx, rcancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer rcancel()
	propagated := false
	for !propagated {
		_, raw, err := ownerConn.Read(rctx)
		if err != nil {
			fail("owner WS read after revoke: %v", err)
		}
		var env struct {
			Type    string         `json:"type"`
			Payload map[string]any `json:"payload"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			fail("owner WS envelope unusable: %v", err)
		}
		if env.Type == "trust.revoked" && env.Payload["subject_device_id"] == subjectID {
			propagated = true
		}
	}
	pass("online propagation, trust.revoked named %s", subjectID)

	// 11. Pre-revoke token dead on heartbeat, devices, decision.
	code, body = postJSON(client, backend+"/v1/presence/heartbeat", withAuth(compTok), map[string]any{"online": true})
	needClosed("post-revoke heartbeat", string(body), code)
	pass("heartbeat rejected after revoke")

	code, body = getJSON(client, backend+"/v1/devices", compTok)
	needClosed("post-revoke devices", string(body), code)
	pass("devices rejected after revoke")

	code, body = postJSON(client, backend+"/v1/pairing/sessions", withAuth(ownerTok), map[string]any{})
	needCode("second session", string(body), code, http.StatusCreated)
	var sess2 struct {
		SessionID string `json:"session_id"`
		QRNonce   string `json:"qr_nonce"`
	}
	if err := json.Unmarshal(body, &sess2); err != nil || sess2.SessionID == "" {
		fail("second session reply unusable: %s", strings.TrimSpace(string(body)))
	}
	p2pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail("cannot generate decoy key: %v", err)
	}
	code, body = postJSON(client, backend+"/v1/pairing/sessions/"+sess2.SessionID+"/join-request", nil, map[string]any{
		"pubkey_b64": b64(p2pub), "fingerprint": mustFP(p2pub),
		"display_name": "DECOY", "request_id": ws.NewUUIDv4(), "qr_nonce": sess2.QRNonce,
	})
	needCode("decoy join", string(body), code, http.StatusOK)
	code, body = postJSON(client, backend+"/v1/pairing/sessions/"+sess2.SessionID+"/decision", withAuth(compTok), map[string]any{
		"approve": false, "subject_pubkey_b64": b64(p2pub),
	})
	needClosed("post-revoke decision", string(body), code)
	pass("decision rejected after revoke")

	// 12. Fresh login refused after revoke.
	code, body = postJSON(client, backend+"/v1/auth/challenge", nil, map[string]any{"device_id": subjectID})
	needCode("post-revoke challenge", string(body), code, http.StatusOK)
	var ch struct {
		Challenge string `json:"challenge"`
	}
	if err := json.Unmarshal(body, &ch); err != nil || ch.Challenge == "" {
		fail("challenge reply unusable: %s", strings.TrimSpace(string(body)))
	}
	sig := ed25519.Sign(compPriv, []byte(ch.Challenge))
	code, body = postJSON(client, backend+"/v1/auth/verify", nil, map[string]any{
		"device_id": subjectID, "challenge": ch.Challenge, "signature_b64": b64(sig),
	})
	needClosed("post-revoke verify", string(body), code)
	pass("verify refused after revoke")

	// 13. Reconnect refused: WS dial with the pre-revoke token.
	dctx, dcancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer dcancel()
	if c, resp, err := websocket.Dial(dctx, wsBase+"/v1/ws?access_token="+compTok, nil); err == nil {
		_ = c.Close(websocket.StatusNormalClosure, "should not connect")
		fail("revoked WS reconnect succeeded")
	} else if resp == nil || (resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden) {
		fail("revoked WS reconnect status = %v, want 401/403", resp)
	}
	pass("reconnect refused after revoke")
	pass("total revoke loop green")
}

func mustFP(pub ed25519.PublicKey) string {
	fp, err := trust.FingerprintEd25519Pub(pub)
	if err != nil {
		fail("cannot fingerprint key: %v", err)
	}
	return fp
}

func login(client *http.Client, backend, deviceID string, priv ed25519.PrivateKey) string {
	tok, _ := loginPair(client, backend, deviceID, priv)
	return tok
}

func loginPair(client *http.Client, backend, deviceID string, priv ed25519.PrivateKey) (string, string) {
	code, body := postJSON(client, backend+"/v1/auth/challenge", nil, map[string]any{"device_id": deviceID})
	needCode("challenge", string(body), code, http.StatusOK)
	var ch struct {
		Challenge string `json:"challenge"`
	}
	if err := json.Unmarshal(body, &ch); err != nil || ch.Challenge == "" {
		fail("challenge reply unusable: %s", strings.TrimSpace(string(body)))
	}
	sig := ed25519.Sign(priv, []byte(ch.Challenge))
	code, body = postJSON(client, backend+"/v1/auth/verify", nil, map[string]any{
		"device_id": deviceID, "challenge": ch.Challenge, "signature_b64": b64(sig),
	})
	needCode("verify", string(body), code, http.StatusOK)
	var tok struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		fail("verify reply unusable: %s", strings.TrimSpace(string(body)))
	}
	return tok.AccessToken, tok.RefreshToken
}

func main() {
	backendFlag := flag.String("backend", e2eBackend, "Backend base URL for the revoke loop")
	nameFlag := flag.String("name", "E2E-PC-REVOKE", "PC display name, 1-64 chars")
	flag.Parse()

	client := &http.Client{Timeout: reqTimeout}
	name := strings.TrimSpace(*nameFlag)
	if name == "" {
		name = "E2E-PC-REVOKE"
	}
	runE2E(client, strings.TrimRight(*backendFlag, "/"), name)
}
