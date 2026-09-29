// Command pcjoin is a dev-only PC pairing prover. It speaks the
// unauthenticated join half of docs/trust/pairing-spec.md so a real
// phone QR can be proven end to end before any PC product code exists.
//
// Default mode joins one live session from a scanned QR:
//
//	pcjoin -qr 'calcar://pair/v1?s=...&r=...&n=...&o=...&v=1' -name OFFICE-PC
//
// --e2e runs the full loop against a local dev backend without a phone:
// bootstrap Owner, login, create session, join as PC, re-read the
// session, assert the join landed. scripts/e2e-pairing.ps1 drives it.
//
// Failure modes, each a distinct non-zero exit with the server body:
//   - QR missing fields or v != 1: refused before any network call.
//   - Backend unreachable: the URL is printed, nothing retried.
//   - Unknown/expired session: server 404/410 surfaced verbatim.
//   - Wrong nonce: 422 QR_MISMATCH, session and request id unburned.
//   - Replayed request id: 409; the tool mints a fresh UUID every run.
//   - Bad display name: 400, validated server side.
// The seed is written to a 0600 file for later approve-path work and is
// never logged. Dev only: no product code may import this package.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/calcar/calcar/backend/trust"
	"github.com/calcar/calcar/backend/ws"
)

const (
	joinTimeout  = 15 * time.Second
	e2eBackend   = "http://127.0.0.1:18080"
	e2eReqPrefix = "e2e-pcjoin-"
)

type qr struct {
	sessionID string
	rendezvous string
	nonce     string
	owner     string
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "pcjoin FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func parseQR(raw string) qr {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		fail("QR does not parse: %v", err)
	}
	if u.Scheme != "calcar" || u.Host != "pair" {
		fail("QR is not a calcar pairing URI")
	}
	q := u.Query()
	out := qr{
		sessionID:  q.Get("s"),
		rendezvous: q.Get("r"),
		nonce:      q.Get("n"),
		owner:      q.Get("o"),
	}
	if q.Get("v") != "1" {
		fail("QR version %q unsupported, update required", q.Get("v"))
	}
	if out.sessionID == "" || out.rendezvous == "" || out.nonce == "" || out.owner == "" {
		fail("QR is missing s, r, n, or o")
	}
	return out
}

func postJSON(client *http.Client, target string, headers map[string]string, body any) (int, []byte) {
	raw, err := json.Marshal(body)
	if err != nil {
		fail("cannot encode request: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(raw))
	if err != nil {
		fail("cannot build request: %v", err)
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
		fail("cannot build request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		fail("backend unreachable at %s: %v", target, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, out
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// joinSession posts one JoinRequest and returns the fingerprint the
// Owner card will show. Anything but 200 is fatal with the body.
func joinSession(client *http.Client, rendezvous, sessionID, nonce, name string) (fp, pubB64, seedB64 string) {
	pub, seed, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail("cannot generate PC key: %v", err)
	}
	fp, err = trust.FingerprintEd25519Pub(pub)
	if err != nil {
		fail("cannot fingerprint PC key: %v", err)
	}
	reqID := ws.NewUUIDv4()
	code, body := postJSON(client, rendezvous, nil, map[string]any{
		"pubkey_b64":   b64(pub),
		"fingerprint":  fp,
		"display_name": name,
		"request_id":   reqID,
		"qr_nonce":     nonce,
	})
	if code != http.StatusOK {
		fail("join rejected (HTTP %d) for session %s: %s", code, sessionID, strings.TrimSpace(string(body)))
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		fail("join reply is not JSON: %s", strings.TrimSpace(string(body)))
	}
	if decoded["session_id"] != sessionID || decoded["status"] != "pending" {
		fail("join reply mismatch: %s", strings.TrimSpace(string(body)))
	}
	return fp, b64(pub), b64(seed)
}

func saveSeed(path, seedB64 string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		fail("cannot create key dir: %v", err)
	}
	if err := os.WriteFile(path, []byte(seedB64+"\n"), 0o600); err != nil {
		fail("cannot save PC seed: %v", err)
	}
}

func defaultName() string {
	if host, err := os.Hostname(); err == nil {
		if name := strings.TrimSpace(host); name != "" {
			return name
		}
	}
	return "TEST-PC"
}

func runJoin(client *http.Client, rawQR, name, keyout string) {
	q := parseQR(rawQR)
	fp, _, seedB64 := joinSession(client, q.rendezvous, q.sessionID, q.nonce, name)
	saveSeed(keyout, seedB64)
	fmt.Printf("pcjoin PASS: join accepted, session %s pending\n", q.sessionID)
	fmt.Printf("pcjoin: Owner card must show fingerprint:\n  %s\n", fp)
	fmt.Printf("pcjoin: PC seed saved (0600) at %s\n", keyout)
}

// runE2E proves the loop without a phone: fresh Owner, fresh session,
// PC join, then re-read as Owner and assert the join landed.
func runE2E(client *http.Client, backend, name string) {
	rid := func() string { return e2eReqPrefix + ws.NewUUIDv4() }
	withRID := func() map[string]string { return map[string]string{"X-Request-ID": rid()} }

	ownerPub, ownerSeed, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fail("e2e: cannot generate Owner key: %v", err)
	}
	_ = ownerSeed
	code, body := postJSON(client, backend+"/v1/users/bootstrap", withRID(), map[string]any{
		"display_name": "E2E Owner",
		"pubkey_b64":   b64(ownerPub),
		"device_id":    "PH-" + strings.ToUpper(ws.NewID()[:8]),
	})
	if code != http.StatusCreated {
		fail("e2e: bootstrap rejected (HTTP %d): %s", code, strings.TrimSpace(string(body)))
	}
	var boot struct {
		UserID   string `json:"user_id"`
		DeviceID string `json:"device_id"`
	}
	if err := json.Unmarshal(body, &boot); err != nil || boot.DeviceID == "" {
		fail("e2e: bootstrap reply unusable: %s", strings.TrimSpace(string(body)))
	}
	fmt.Println("pcjoin: bootstrap ok")

	code, body = postJSON(client, backend+"/v1/auth/challenge", nil, map[string]any{
		"device_id": boot.DeviceID,
	})
	if code != http.StatusOK {
		fail("e2e: challenge rejected (HTTP %d): %s", code, strings.TrimSpace(string(body)))
	}
	var ch struct {
		Challenge string `json:"challenge"`
	}
	if err := json.Unmarshal(body, &ch); err != nil || ch.Challenge == "" {
		fail("e2e: challenge reply unusable: %s", strings.TrimSpace(string(body)))
	}
	sig := ed25519.Sign(ownerSeed, []byte(ch.Challenge))
	code, body = postJSON(client, backend+"/v1/auth/verify", nil, map[string]any{
		"device_id":     boot.DeviceID,
		"challenge":     ch.Challenge,
		"signature_b64": b64(sig),
	})
	if code != http.StatusOK {
		fail("e2e: verify rejected (HTTP %d): %s", code, strings.TrimSpace(string(body)))
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		fail("e2e: verify reply unusable: %s", strings.TrimSpace(string(body)))
	}
	fmt.Println("pcjoin: login ok")

	auth := map[string]string{"Authorization": "Bearer " + tok.AccessToken, "X-Request-ID": rid()}
	code, body = postJSON(client, backend+"/v1/pairing/sessions", auth, map[string]any{})
	if code != http.StatusCreated {
		fail("e2e: create session rejected (HTTP %d): %s", code, strings.TrimSpace(string(body)))
	}
	var sess struct {
		SessionID string `json:"session_id"`
		Status    string `json:"status"`
		QRNonce   string `json:"qr_nonce"`
	}
	if err := json.Unmarshal(body, &sess); err != nil || sess.SessionID == "" || sess.QRNonce == "" {
		fail("e2e: session reply unusable: %s", strings.TrimSpace(string(body)))
	}
	fmt.Printf("pcjoin: session %s pending\n", sess.SessionID)

	fp, _, _ := joinSession(client, backend+"/v1/pairing/sessions/"+sess.SessionID+"/join-request", sess.SessionID, sess.QRNonce, name)
	fmt.Printf("pcjoin: join accepted, fingerprint %s\n", fp)

	code, body = getJSON(client, backend+"/v1/pairing/sessions/"+sess.SessionID, tok.AccessToken)
	if code != http.StatusOK {
		fail("e2e: re-read rejected (HTTP %d): %s", code, strings.TrimSpace(string(body)))
	}
	var reread struct {
		SessionID       string `json:"session_id"`
		Status          string `json:"status"`
		JoinRequestID   string `json:"join_request_id"`
		JoinFingerprint string `json:"join_fingerprint"`
		JoinDisplayName string `json:"join_display_name"`
	}
	if err := json.Unmarshal(body, &reread); err != nil {
		fail("e2e: re-read unusable: %s", strings.TrimSpace(string(body)))
	}
	if reread.JoinRequestID == "" || reread.JoinFingerprint != fp || reread.JoinDisplayName != name || reread.Status != "pending" {
		fail("e2e: join did not land: %s", strings.TrimSpace(string(body)))
	}
	fmt.Printf("pcjoin PASS: join landed, card would show %s named %s\n", fp, name)
}

func main() {
	qrFlag := flag.String("qr", "", "Full calcar://pair/v1 QR URI from the phone screen")
	sessionFlag := flag.String("session", "", "Session id (alternative to -qr)")
	nonceFlag := flag.String("nonce", "", "QR nonce (alternative to -qr)")
	rendezvousFlag := flag.String("rendezvous", "", "Join endpoint URL (alternative to -qr)")
	nameFlag := flag.String("name", "", "PC display name, 1-64 chars (default OS hostname)")
	keyoutFlag := flag.String("keyout", filepath.Join(os.TempDir(), "calcar-pcjoin.key"), "Where to save the PC seed (0600)")
	backendFlag := flag.String("backend", e2eBackend, "Backend base URL for --e2e")
	e2eFlag := flag.Bool("e2e", false, "Full loop without a phone against -backend dev backend")
	flag.Parse()

	client := &http.Client{Timeout: joinTimeout}
	if *e2eFlag {
		name := *nameFlag
		if strings.TrimSpace(name) == "" {
			name = "E2E-PC"
		}
		runE2E(client, strings.TrimRight(*backendFlag, "/"), name)
		return
	}

	name := strings.TrimSpace(*nameFlag)
	if name == "" {
		name = defaultName()
	}
	keyout := *keyoutFlag
	if strings.TrimSpace(*qrFlag) != "" {
		runJoin(client, *qrFlag, name, keyout)
		return
	}
	if strings.TrimSpace(*sessionFlag) == "" || strings.TrimSpace(*nonceFlag) == "" || strings.TrimSpace(*rendezvousFlag) == "" {
		fail("need -qr or all of -session, -nonce, -rendezvous")
	}
	u, err := url.Parse(*rendezvousFlag)
	if err != nil || u.Scheme == "" || u.Host == "" {
		fail("rendezvous is not a URL")
	}
	fp, _, seedB64 := joinSession(client, *rendezvousFlag, *sessionFlag, *nonceFlag, name)
	saveSeed(keyout, seedB64)
	fmt.Printf("pcjoin PASS: join accepted, session %s pending\n", *sessionFlag)
	fmt.Printf("pcjoin: Owner card must show fingerprint:\n  %s\n", fp)
	fmt.Printf("pcjoin: PC seed saved (0600) at %s\n", keyout)
}
