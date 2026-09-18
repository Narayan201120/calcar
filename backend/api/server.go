// Package api is the P3 HTTP control plane: identity, pairing, trust,
// presence, and push fan-out. JSON everywhere; field names mirror the
// proto (snake_case). WebSocket signals live in backend/ws; this server
// owns one ws.Hub and notifies it after each committed state change.
package api

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/calcar/calcar/backend/store"
	"github.com/calcar/calcar/backend/trust"
	"github.com/calcar/calcar/backend/ws"
)

// Defaults and limits.
const (
	// DefaultTokenTTL is the opaque access-token lifetime (24h per P3).
	DefaultTokenTTL = 24 * time.Hour
	// RequestIDTTL bounds replay defence for mutation idempotency keys.
	RequestIDTTL = 24 * time.Hour
	// ChallengeExpiresIn is advertised for auth challenges; the store
	// enforces the real 2-minute TTL (pairing spec section 8).
	ChallengeExpiresIn = 120
	// PairingTTL is the session TTL: 10 minutes (DEC-024).
	PairingTTL = 10 * time.Minute

	maxDisplayName = 64
	maxReason      = 280
	maxIDLen       = 128
	maxKindLen     = 64
	maxPlatformLen = 32
	maxPushTokLen  = 512
)

type ctxKey int

const (
	ctxDevice ctxKey = iota
	ctxUserID
)

// Server is the HTTP control plane. Construct with NewServer; it serves
// the full route table itself so httptest and main share one wiring.
type Server struct {
	st       store.Store
	hub      *ws.Hub
	mux      *http.ServeMux
	TokenTTL time.Duration
	now      func() time.Time
}

// NewServer wires all routes against st. The hub is created here and
// driven by callers via Hub().Go(); Hub().Notify delivers WS signals.
func NewServer(st store.Store) *Server {
	s := &Server{
		st:       st,
		hub:      ws.NewHub(st),
		mux:      http.NewServeMux(),
		TokenTTL: DefaultTokenTTL,
		now:      time.Now,
	}
	s.routes()
	return s
}

// Hub exposes the WS fan-out hub for Run/Notify wiring.
func (s *Server) Hub() *ws.Hub { return s.hub }

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

func (s *Server) routes() {
	m := s.mux
	// Ops, no auth.
	m.HandleFunc("GET /healthz", s.handleHealthz)
	m.HandleFunc("GET /readyz", s.handleReadyz)
	// Bootstrap + auth, no token yet.
	m.HandleFunc("POST /v1/users/bootstrap", s.handleBootstrap)
	m.HandleFunc("POST /v1/auth/challenge", s.handleChallenge)
	m.HandleFunc("POST /v1/auth/verify", s.handleVerify)
	// Devices.
	m.HandleFunc("GET /v1/devices", s.authed(s.handleDevicesList))
	m.HandleFunc("POST /v1/devices", s.authed(s.handleDevicesRegister))
	m.HandleFunc("POST /v1/devices/{id}/revoke", s.authed(s.handleDeviceRevoke))
	m.HandleFunc("POST /v1/devices/{id}/push-token", s.authed(s.handlePushToken))
	// Pairing.
	m.HandleFunc("POST /v1/pairing/sessions", s.authed(s.handlePairingCreate))
	m.HandleFunc("POST /v1/pairing/sessions/{id}/join-request", s.handlePairingJoin)
	m.HandleFunc("GET /v1/pairing/sessions/{id}", s.authed(s.handlePairingGet))
	m.HandleFunc("POST /v1/pairing/sessions/{id}/decision", s.authed(s.handlePairingDecision))
	// Trust, presence, notify, relay stub.
	m.HandleFunc("GET /v1/trust/graph", s.authed(s.handleTrustGraph))
	m.HandleFunc("POST /v1/presence/heartbeat", s.authed(s.handleHeartbeat))
	m.HandleFunc("GET /v1/computers/{id}/presence", s.authed(s.handlePresenceGet))
	m.HandleFunc("POST /v1/notify/attention", s.authed(s.handleAttention))
	m.HandleFunc("POST /v1/relay/alloc", s.handleRelayAlloc)
	// Signals.
	m.Handle("GET /v1/ws", s.hub)
}

// ---- request context ----

func deviceOf(r *http.Request) store.Device { return r.Context().Value(ctxDevice).(store.Device) }
func userOf(r *http.Request) string         { return r.Context().Value(ctxUserID).(string) }

// authed resolves the bearer token, loads the device, and rejects
// revoked devices before the handler runs. Revoked: 401 when the token
// itself is dead, 403 when the device record says revoked but the token
// still resolves (fail closed either way; P3 gate wants 401-or-403).
func (s *Server) authed(next func(http.ResponseWriter, *http.Request)) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r.Header.Get("Authorization"))
		if token == "" {
			writeErr(w, http.StatusUnauthorized, "MISSING_TOKEN", "bearer token required", true)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		deviceID, userID, err := s.st.ResolveAccessToken(ctx, token)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, trust.CodeRevoked, "invalid or expired token", false)
			return
		}
		dev, err := s.st.GetDevice(ctx, deviceID)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, trust.CodeRevoked, "unknown device", false)
			return
		}
		if dev.Revoked {
			writeErr(w, http.StatusForbidden, trust.CodeRevoked, "device revoked", false)
			return
		}
		if revoked, rerr := s.st.IsRevoked(ctx, deviceID); rerr == nil && revoked {
			writeErr(w, http.StatusForbidden, trust.CodeRevoked, "device revoked", false)
			return
		}
		r = r.WithContext(context.WithValue(r.Context(), ctxDevice, dev))
		r = r.WithContext(context.WithValue(r.Context(), ctxUserID, userID))
		next(w, r)
	}
}

// idempotent enforces the X-Request-ID mutation key via
// CheckAndMarkRequest (24h TTL). Missing: 400. Reused: 409 REPLAYED_ID.
// Join-request carries its own body request_id instead of the header.
func (s *Server) idempotent(w http.ResponseWriter, r *http.Request) (string, bool) {
	rid := strings.TrimSpace(r.Header.Get("X-Request-ID"))
	if rid == "" {
		writeErr(w, http.StatusBadRequest, "MISSING_REQUEST_ID", "X-Request-ID header required", false)
		return "", false
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := s.st.CheckAndMarkRequest(ctx, rid, RequestIDTTL); err != nil {
		if errors.Is(err, store.ErrReplayed) {
			writeErr(w, http.StatusConflict, trust.CodeReplayedID, "request id already used", false)
			return "", false
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "replay check failed", true)
		return "", false
	}
	return rid, true
}

// ---- JSON helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

type errBody struct {
	Error     string `json:"error"`
	Message   string `json:"message,omitempty"`
	Retryable bool   `json:"retryable"`
}

func writeErr(w http.ResponseWriter, status int, code, msg string, retryable bool) {
	writeJSON(w, status, errBody{Error: code, Message: msg, Retryable: retryable})
}

// storeErr maps seam errors to the pairing-spec transport table.
func storeErr(w http.ResponseWriter, err error, expiredCode, goneCode string) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, trust.CodeUnknownSession, "unknown session or device", false)
	case errors.Is(err, store.ErrExpired):
		writeErr(w, http.StatusGone, expiredCode, "session expired", false)
	case errors.Is(err, store.ErrGone):
		writeErr(w, http.StatusGone, goneCode, "session already consumed", false)
	case errors.Is(err, store.ErrForbidden):
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "forbidden", false)
	case errors.Is(err, store.ErrReplayed):
		writeErr(w, http.StatusConflict, trust.CodeReplayedID, "request id already used", false)
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, trust.CodeReplayedID, "already exists", false)
	default:
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "store failure", true)
	}
	return true
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "malformed JSON: "+err.Error(), false)
		return false
	}
	return true
}

func bearerToken(hdr string) string {
	if hdr == "" {
		return ""
	}
	parts := strings.SplitN(hdr, " ", 2)
	if len(parts) == 2 && strings.EqualFold(parts[0], "bearer") {
		return strings.TrimSpace(parts[1])
	}
	return ""
}

func decodePubKey(b64 string) ([]byte, bool) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		raw, err = base64.URLEncoding.DecodeString(strings.TrimSpace(b64))
		if err != nil {
			raw, err = base64.RawURLEncoding.DecodeString(strings.TrimSpace(b64))
			if err != nil {
				return nil, false
			}
		}
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, false
	}
	return raw, true
}

func encodePubKey(pub []byte) string { return base64.StdEncoding.EncodeToString(pub) }

func checkDisplayName(name string) (string, bool) {
	t := strings.TrimSpace(name)
	return t, t != "" && len(t) <= maxDisplayName
}

// userHasOwner reports whether the user already has an Owner device.
// Second Owner registration is rejected with 403 (P2 invariant I1).
func (s *Server) userHasOwner(ctx context.Context, userID string) (bool, error) {
	devs, err := s.st.ListUserDevices(ctx, userID)
	if err != nil {
		return false, err
	}
	for _, d := range devs {
		if d.Role == store.RoleOwnerPhone && !d.Revoked {
			return true, nil
		}
	}
	return false, nil
}

// ---- ops ----

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.st.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "NOT_READY", "dependency unhealthy", true)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ready"})
}

// ---- bootstrap + auth ----

type bootstrapReq struct {
	DisplayName string `json:"display_name"`
	PubKeyB64   string `json:"pubkey_b64"`
	DeviceID    string `json:"device_id"`
}

// handleBootstrap creates the user and registers the first Owner phone.
// NOTE on rate limiting: this endpoint must be throttled (per-IP burst
// + global allowlist) once the Redis-backed limiter lands; until then
// deploy behind Caddy basic-auth or a one-shot setup token. Open item.
func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	var req bootstrapReq
	if !decode(w, r, &req) {
		return
	}
	name, ok := checkDisplayName(req.DisplayName)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "display_name must be 1-64 chars", false)
		return
	}
	pub, ok := decodePubKey(req.PubKeyB64)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "pubkey_b64 must be a 32-byte Ed25519 key", false)
		return
	}
	fp, err := trust.FingerprintEd25519Pub(pub)
	if err != nil {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "invalid public key", false)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	userID, err := s.st.CreateUser(ctx)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "create user failed", true)
		return
	}
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		deviceID = "PH-" + strings.ToUpper(ws.NewID()[:8])
	}
	if len(deviceID) > maxIDLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "device_id too long", false)
		return
	}
	// Fresh users cannot have a second Owner by construction; the guard
	// below keeps the invariant explicit if the seam ever reuses users.
	if has, herr := s.userHasOwner(ctx, userID); herr != nil || has {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "owner already established", false)
		return
	}
	derr := s.st.RegisterDevice(ctx, store.Device{
		ID:          deviceID,
		UserID:      userID,
		Role:        store.RoleOwnerPhone,
		DisplayName: name,
		PubKey:      pub,
		Fingerprint: fp,
	})
	if derr != nil {
		if errors.Is(derr, store.ErrConflict) {
			writeErr(w, http.StatusConflict, trust.CodeReplayedID, "device already registered", false)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "register device failed", true)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"user_id":     userID,
		"device_id":   deviceID,
		"role":        store.RoleOwnerPhone,
		"fingerprint": fp,
	})
}

type challengeReq struct {
	DeviceID string `json:"device_id"`
}

func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	var req challengeReq
	if !decode(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.DeviceID) == "" {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "device_id required", false)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if _, err := s.st.GetDevice(ctx, req.DeviceID); err != nil {
		writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
		return
	}
	ch, err := s.st.IssueChallenge(ctx, req.DeviceID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "challenge failed", true)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"device_id":          req.DeviceID,
		"challenge":          ch,
		"expires_in_seconds": ChallengeExpiresIn,
	})
}

type verifyReq struct {
	DeviceID     string `json:"device_id"`
	Challenge    string `json:"challenge"`
	SignatureB64 string `json:"signature_b64"`
}

// handleVerify checks the Ed25519 signature over the exact challenge
// string bytes against the registered device pubkey, then mints an
// opaque 24h token. Test-only signers are forbidden here by
// construction: verification uses only the stored pubkey.
func (s *Server) handleVerify(w http.ResponseWriter, r *http.Request) {
	var req verifyReq
	if !decode(w, r, &req) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	dev, err := s.st.GetDevice(ctx, req.DeviceID)
	if err != nil {
		writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
		return
	}
	if dev.Revoked {
		writeErr(w, http.StatusForbidden, trust.CodeRevoked, "device revoked", false)
		return
	}
	if revoked, rerr := s.st.IsRevoked(ctx, req.DeviceID); rerr == nil && revoked {
		writeErr(w, http.StatusForbidden, trust.CodeRevoked, "device revoked", false)
		return
	}
	sig, serr := base64.StdEncoding.DecodeString(strings.TrimSpace(req.SignatureB64))
	if serr != nil || len(sig) != ed25519.SignatureSize {
		writeErr(w, http.StatusUnauthorized, trust.CodeBadSignature, "invalid signature", false)
		return
	}
	if err := s.st.ConsumeChallenge(ctx, req.DeviceID, req.Challenge); err != nil {
		writeErr(w, http.StatusUnauthorized, "INVALID_CHALLENGE", "challenge unknown or expired", false)
		return
	}
	if !ed25519.Verify(ed25519.PublicKey(dev.PubKey), []byte(req.Challenge), sig) {
		writeErr(w, http.StatusUnauthorized, trust.CodeBadSignature, "signature verification failed", false)
		return
	}
	tok, err := s.st.IssueAccessToken(ctx, dev.ID, dev.UserID, s.TokenTTL)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "token issue failed", true)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token":       tok,
		"token_type":         "bearer",
		"expires_in_seconds": int(s.TokenTTL / time.Second),
	})
}

// ---- devices ----

func deviceJSON(d store.Device) map[string]any {
	return map[string]any{
		"device_id":     d.ID,
		"role":          d.Role,
		"display_name":  d.DisplayName,
		"pubkey_b64":    encodePubKey(d.PubKey),
		"fingerprint":   d.Fingerprint,
		"revoked":       d.Revoked,
		"authorized_by": d.AuthorizedBy,
	}
}

func (s *Server) handleDevicesList(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	devs, err := s.st.ListUserDevices(ctx, userOf(r))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "list failed", true)
		return
	}
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, deviceJSON(d))
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

type registerReq struct {
	DeviceID    string `json:"device_id"`
	DisplayName string `json:"display_name"`
	PubKeyB64   string `json:"pubkey_b64"`
	Fingerprint string `json:"fingerprint"`
	Role        string `json:"role"`
}

// handleDevicesRegister registers a phone/computer or updates a
// registered device's display name only. Keys are immutable: a pubkey
// or fingerprint change is 422, never an update.
func (s *Server) handleDevicesRegister(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	var req registerReq
	if !decode(w, r, &req) {
		return
	}
	me := deviceOf(r)
	if strings.TrimSpace(req.DeviceID) == "" || len(req.DeviceID) > maxIDLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "device_id required, max 128 chars", false)
		return
	}
	name, ok := checkDisplayName(req.DisplayName)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "display_name must be 1-64 chars", false)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	existing, err := s.st.GetDevice(ctx, req.DeviceID)
	if err == nil {
		if existing.UserID != me.UserID {
			writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "device belongs to another user", false)
			return
		}
		pub, ok := decodePubKey(req.PubKeyB64)
		if !ok {
			writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "pubkey_b64 must be a 32-byte Ed25519 key", false)
			return
		}
		if string(existing.PubKey) != string(pub) {
			writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "device keys are immutable; re-pair for a new identity", false)
			return
		}
		if req.Fingerprint != "" && req.Fingerprint != existing.Fingerprint {
			writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "fingerprint is immutable", false)
			return
		}
		updated := existing
		updated.DisplayName = name
		if rerr := s.st.RegisterDevice(ctx, updated); rerr != nil && !errors.Is(rerr, store.ErrConflict) {
			writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "update failed", true)
			return
		}
		// ErrConflict from non-upsert stores means the row already holds
		// these keys; re-read to return current truth.
		if cur, gerr := s.st.GetDevice(ctx, req.DeviceID); gerr == nil {
			updated = cur
			updated.DisplayName = name // display intent stands even if store is insert-only
		}
		writeJSON(w, http.StatusOK, deviceJSON(updated))
		return
	}
	if !errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "lookup failed", true)
		return
	}
	role := strings.TrimSpace(req.Role)
	if role == "" {
		role = store.RoleTrustedPhone
	}
	switch role {
	case store.RoleOwnerPhone:
		if has, herr := s.userHasOwner(ctx, me.UserID); herr != nil {
			writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "lookup failed", true)
			return
		} else if has {
			writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "owner already established", false)
			return
		}
	case store.RoleTrustedPhone, store.RoleComputer:
	default:
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "role must be owner_phone, trusted_phone, or computer", false)
		return
	}
	pub, ok := decodePubKey(req.PubKeyB64)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "pubkey_b64 must be a 32-byte Ed25519 key", false)
		return
	}
	fp, ferr := trust.FingerprintEd25519Pub(pub)
	if ferr != nil {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "invalid public key", false)
		return
	}
	if req.Fingerprint != "" && req.Fingerprint != fp {
		writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "fingerprint does not derive from pubkey", false)
		return
	}
	dev := store.Device{
		ID:           req.DeviceID,
		UserID:       me.UserID,
		Role:         role,
		DisplayName:  name,
		PubKey:       pub,
		Fingerprint:  fp,
		AuthorizedBy: me.ID,
	}
	if rerr := s.st.RegisterDevice(ctx, dev); storeErr(w, rerr, trust.CodePairingExpired, trust.CodePairingConsumed) && rerr != nil {
		return
	}
	writeJSON(w, http.StatusCreated, deviceJSON(dev))
}

type revokeReq struct {
	Reason string `json:"reason"`
}

// handleDeviceRevoke revokes a same-user device and kills its tokens.
// Caller must be a phone (Owner or trusted); computers get 403 per I2.
func (s *Server) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	if me.Role == store.RoleComputer {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "computers cannot revoke devices", false)
		return
	}
	var req revokeReq
	if r.ContentLength != 0 && !decode(w, r, &req) {
		return
	}
	reason := strings.TrimSpace(req.Reason)
	if len(reason) > maxReason {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "reason max 280 chars", false)
		return
	}
	target := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	dev, err := s.st.GetDevice(ctx, target)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "lookup failed", true)
		return
	}
	if dev.UserID != me.UserID {
		writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
		return
	}
	if err := s.st.RevokeDevice(ctx, target, me.ID, reason); storeErr(w, err, trust.CodePairingExpired, trust.CodePairingConsumed) && err != nil {
		return
	}
	if err := s.st.RevokeDeviceTokens(ctx, target); err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "token revocation failed", true)
		return
	}
	s.hub.Notify(ws.Event{UserID: me.UserID, Type: ws.EventTrustRevoked,
		Payload: map[string]any{"subject_device_id": target, "revoker_device_id": me.ID}})
	writeJSON(w, http.StatusOK, map[string]any{"device_id": target, "revoked": true})
}

type pushTokenReq struct {
	Platform  string `json:"platform"`
	PushToken string `json:"push_token"`
}

func (s *Server) handlePushToken(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	var req pushTokenReq
	if !decode(w, r, &req) {
		return
	}
	platform := strings.TrimSpace(req.Platform)
	if platform == "" || len(platform) > maxPlatformLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "platform required, max 32 chars", false)
		return
	}
	if strings.TrimSpace(req.PushToken) == "" || len(req.PushToken) > maxPushTokLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "push_token required, max 512 chars", false)
		return
	}
	target := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	dev, err := s.st.GetDevice(ctx, target)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "lookup failed", true)
		return
	}
	if dev.UserID != me.UserID {
		writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
		return
	}
	if err := s.st.SetPushToken(ctx, target, platform, req.PushToken); err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "push token store failed", true)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"device_id": target, "platform": platform})
}

// ---- trust graph ----

func (s *Server) handleTrustGraph(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	devs, err := s.st.ListUserDevices(ctx, userOf(r))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "list failed", true)
		return
	}
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, deviceJSON(d))
	}
	// NOTE: grants[] stays empty until the seam gains grant listing;
	// edges are derivable today from devices[].authorized_by.
	writeJSON(w, http.StatusOK, map[string]any{"devices": out, "grants": []any{}})
}

// ---- presence / attention / relay ----

type heartbeatReq struct {
	Online *bool `json:"online"`
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	online := true
	if r.ContentLength != 0 {
		var req heartbeatReq
		if !decode(w, r, &req) {
			return
		}
		if req.Online != nil {
			online = *req.Online
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	p := store.Presence{DeviceID: me.ID, Online: online, ConnID: "http", LastSeen: s.now()}
	if err := s.st.SetPresence(ctx, p); err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "presence failed", true)
		return
	}
	s.hub.Notify(ws.Event{UserID: me.UserID, Type: ws.EventPresenceChanged,
		Payload: map[string]any{"device_id": me.ID, "online": online}})
	writeJSON(w, http.StatusOK, map[string]any{
		"device_id": me.ID, "online": online,
		"last_seen_millis": p.LastSeen.UnixMilli(),
	})
}

func (s *Server) handlePresenceGet(w http.ResponseWriter, r *http.Request) {
	me := deviceOf(r)
	target := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	dev, err := s.st.GetDevice(ctx, target)
	if err != nil || dev.UserID != me.UserID {
		writeErr(w, http.StatusNotFound, "UNKNOWN_DEVICE", "unknown device", false)
		return
	}
	p, err := s.st.GetPresence(ctx, target)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "NO_PRESENCE", "no presence recorded", false)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "presence lookup failed", true)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"device_id": p.DeviceID, "online": p.Online,
		"last_seen_millis": p.LastSeen.UnixMilli(),
	})
}

type attentionReq struct {
	ComputerID string `json:"computer_id"`
	WorkflowID string `json:"workflow_id"`
	Kind       string `json:"kind"`
}

// handleAttention accepts opaque ids+kind only from the owning computer.
// Bodies, prompts, terminal, and diffs are banned here by shape: only
// three short strings exist, with max lengths enforced.
func (s *Server) handleAttention(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	if me.Role != store.RoleComputer {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "only a computer posts attention", false)
		return
	}
	var req attentionReq
	if !decode(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.ComputerID) == "" || len(req.ComputerID) > maxIDLen ||
		strings.TrimSpace(req.WorkflowID) == "" || len(req.WorkflowID) > maxIDLen ||
		strings.TrimSpace(req.Kind) == "" || len(req.Kind) > maxKindLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "computer_id, workflow_id (max 128) and kind (max 64) required", false)
		return
	}
	if req.ComputerID != me.ID {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "computer_id must be the caller", false)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	a := store.Attention{ComputerID: req.ComputerID, WorkflowID: req.WorkflowID, Kind: req.Kind}
	if err := s.st.EnqueueAttention(ctx, me.UserID, a); err != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "enqueue failed", true)
		return
	}
	s.hub.Notify(ws.Event{UserID: me.UserID, Type: ws.EventAttentionPending,
		Payload: map[string]any{"computer_id": a.ComputerID, "workflow_id": a.WorkflowID, "kind": a.Kind}})
	writeJSON(w, http.StatusAccepted, map[string]any{"queued": true})
}

// handleRelayAlloc is the P8 relay stub: always 501 with a stable
// schema so clients can branch without parsing messages.
func (s *Server) handleRelayAlloc(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotImplemented)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": "relay_not_configured", "retryable": false,
	})
}
