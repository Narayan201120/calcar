package api

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/calcar/calcar/backend/store"
	"github.com/calcar/calcar/backend/trust"
	"github.com/calcar/calcar/backend/ws"

	calcarv1 "github.com/calcar/calcar/backend/gen/calcar/v1"
)

func sessionJSON(s store.PairingSession) map[string]any {
	out := map[string]any{
		"session_id":        s.ID,
		"status":            s.Status,
		"owner_device_id":   s.CreatedBy,
		"expires_at_millis": s.ExpiresAt.UnixMilli(),
		"qr_nonce":          s.QRNonce,
	}
	if s.JoinRequestID != "" {
		out["join_request_id"] = s.JoinRequestID
		out["join_fingerprint"] = s.JoinFingerprint
		out["join_display_name"] = s.JoinName
	}
	return out
}

// handlePairingCreate mints a phone-created session: crypto-random
// 128-bit session id plus 128-bit QR nonce, 10-minute TTL (DEC-024).
// Phones only; computers get 403.
func (s *Server) handlePairingCreate(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	if me.Role == store.RoleComputer {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "only a phone creates pairing sessions", false)
		return
	}
	now := s.now()
	sess := store.PairingSession{
		ID:        ws.NewUUIDv4(),
		UserID:    me.UserID,
		CreatedBy: me.ID,
		Status:    store.SessionPending,
		ExpiresAt: now.Add(PairingTTL),
		QRNonce:   ws.NewNonceB64URL(),
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := s.st.CreatePairingSession(ctx, sess); err != nil {
		if errors.Is(err, store.ErrConflict) || errors.Is(err, store.ErrReplayed) {
			writeErr(w, http.StatusConflict, trust.CodeReplayedID, "session id collision, retry", true)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "create session failed", true)
		return
	}
	writeJSON(w, http.StatusCreated, sessionJSON(sess))
}

type joinReq struct {
	PubKeyB64   string `json:"pubkey_b64"`
	Fingerprint string `json:"fingerprint"`
	DisplayName string `json:"display_name"`
	RequestID   string `json:"request_id"`
}

// handlePairingJoin is the UNAUTHENTICATED computer call. Validates in
// spec order: live pending session, unseen request id, 32-byte key,
// fingerprint derivation, display name. Expired: 410 PAIRING_EXPIRED.
// Second join: 410 PAIRING_CONSUMED. Unknown id: 404.
func (s *Server) handlePairingJoin(w http.ResponseWriter, r *http.Request) {
	var req joinReq
	if !decode(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.RequestID) == "" {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "request_id required", false)
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
	if strings.TrimSpace(req.Fingerprint) != fp {
		writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "fingerprint does not derive from pubkey", false)
		return
	}
	name, ok := checkDisplayName(req.DisplayName)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "display_name must be 1-64 chars", false)
		return
	}
	sessionID := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	sess, err := s.st.GetPairingSession(ctx, sessionID)
	if err != nil {
		storeErr(w, err, trust.CodePairingExpired, trust.CodePairingConsumed)
		return
	}
	if s.now().After(sess.ExpiresAt) {
		writeErr(w, http.StatusGone, trust.CodePairingExpired, "session expired", false)
		return
	}
	// Body request_id doubles as the idempotency key here (no header on
	// the unauthenticated call); reuse is 409 REPLAYED_ID.
	if cerr := s.st.CheckAndMarkRequest(ctx, req.RequestID, RequestIDTTL); cerr != nil {
		if errors.Is(cerr, store.ErrReplayed) {
			writeErr(w, http.StatusConflict, trust.CodeReplayedID, "request id already used", false)
			return
		}
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "replay check failed", true)
		return
	}
	if jerr := s.st.SubmitJoinRequest(ctx, sessionID, pub, fp, name, req.RequestID); jerr != nil {
		storeErr(w, jerr, trust.CodePairingExpired, trust.CodePairingConsumed)
		return
	}
	s.hub.Notify(ws.Event{UserID: sess.UserID, Type: ws.EventPairingJoinRequested,
		Payload: map[string]any{
			"session_id": sessionID, "display_name": name,
			"fingerprint": fp, "request_id": req.RequestID,
			// requested_at_millis is the creation proxy (expires_at minus
			// the 10-minute TTL). The seam stores no join timestamp, so
			// the phone MUST reuse this value verbatim in ContextHash;
			// the backend recomputes the same proxy at decision time.
			"requested_at_millis": requestedAtProxy(sess),
		}})
	writeJSON(w, http.StatusOK, map[string]any{"session_id": sessionID, "status": store.SessionPending})
}

// handlePairingGet returns the session to its creating phone only.
func (s *Server) handlePairingGet(w http.ResponseWriter, r *http.Request) {
	me := deviceOf(r)
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	sess, err := s.st.GetPairingSession(ctx, r.PathValue("id"))
	if err != nil {
		storeErr(w, err, trust.CodePairingExpired, trust.CodePairingConsumed)
		return
	}
	if sess.CreatedBy != me.ID {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "only the creating phone may read this session", false)
		return
	}
	writeJSON(w, http.StatusOK, sessionJSON(sess))
}

type decisionReq struct {
	Approve          bool   `json:"approve"`
	SubjectPubKeyB64 string `json:"subject_pubkey_b64"`
	SignatureB64     string `json:"signature_b64"`
	// Phone-chosen signed fields (spec section 7: the Owner constructs
	// the AuthorizationRecord). The backend binds session_id,
	// subject_device_id, subject_public_key, owner_device_id, and the
	// recomputed context_hash itself; the phone MUST sign exactly the
	// record these fields plus the server bindings produce.
	AuthorizationID string `json:"authorization_id"`
	NonceB64        string `json:"nonce_b64"`
	DecidedAtMillis int64  `json:"decided_at_millis"`
}

// requestedAtProxy reconstructs the join-time proxy for the context
// hash. The seam carries no requested_at_millis, so both phone and
// backend derive creation as expires_at minus the 10-minute TTL and
// treat the join as simultaneous. OPEN ITEM: extend the seam with the
// join timestamp so ContextHash binds the real Owner-seen time.
func requestedAtProxy(sess store.PairingSession) int64 {
	return sess.ExpiresAt.Add(-PairingTTL).UnixMilli()
}

// handlePairingDecision approves or rejects a join. Caller must be the
// active Owner (owner_phone role, same user); computers get 403, never
// a grant (I2). On approve the subject pubkey must match the stored
// join exactly (else 422) and the Owner signature must verify via
// trust.VerifyAuthorization over the deterministic protobuf payload.
// Double decide is 410 PAIRING_CONSUMED: first outcome stands.
func (s *Server) handlePairingDecision(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.idempotent(w, r); !ok {
		return
	}
	me := deviceOf(r)
	if me.Role != store.RoleOwnerPhone {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "only the Owner device decides pairing", false)
		return
	}
	var req decisionReq
	if !decode(w, r, &req) {
		return
	}
	subjectPub, ok := decodePubKey(req.SubjectPubKeyB64)
	if !ok {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "subject_pubkey_b64 must be a 32-byte Ed25519 key", false)
		return
	}
	sessionID := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	sess, err := s.st.GetPairingSession(ctx, sessionID)
	if err != nil {
		storeErr(w, err, trust.CodePairingExpired, trust.CodePairingConsumed)
		return
	}
	if sess.UserID != me.UserID {
		writeErr(w, http.StatusForbidden, trust.CodeNotOwner, "session belongs to another user", false)
		return
	}
	if s.now().After(sess.ExpiresAt) {
		writeErr(w, http.StatusGone, trust.CodePairingExpired, "session expired", false)
		return
	}
	if len(sess.JoinPubKey) == 0 {
		writeErr(w, http.StatusConflict, trust.CodeInvalidInput, "no join request on this session", false)
		return
	}
	if string(subjectPub) != string(sess.JoinPubKey) {
		writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "subject pubkey differs from join pubkey", false)
		return
	}
	if fp, ferr := trust.FingerprintEd25519Pub(subjectPub); ferr != nil || fp != sess.JoinFingerprint {
		writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, "fingerprint does not derive from pubkey", false)
		return
	}
	subjectDeviceID, derr := trust.DeviceIDForComputer(subjectPub)
	if derr != nil {
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "device id derivation failed", true)
		return
	}

	if !req.Approve {
		if derr := s.st.DecidePairingSession(ctx, sessionID, false, nil, nil, me.ID); derr != nil {
			storeErr(w, derr, trust.CodePairingExpired, trust.CodePairingConsumed)
			return
		}
		s.hub.Notify(ws.Event{UserID: sess.UserID, Type: ws.EventPairingDecided,
			Payload: map[string]any{"session_id": sessionID, "approved": false}})
		writeJSON(w, http.StatusOK, map[string]any{"session_id": sessionID, "status": store.SessionRejected})
		return
	}

	sig, serr := base64.StdEncoding.DecodeString(strings.TrimSpace(req.SignatureB64))
	if serr != nil {
		sig, serr = base64.URLEncoding.DecodeString(strings.TrimSpace(req.SignatureB64))
	}
	if serr != nil || len(sig) != ed25519.SignatureSize {
		writeErr(w, http.StatusUnauthorized, trust.CodeBadSignature, "owner signature required for approval", false)
		return
	}
	if strings.TrimSpace(req.AuthorizationID) == "" || len(req.AuthorizationID) > maxIDLen {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "authorization_id required, max 128 chars", false)
		return
	}
	nonce, nerr := base64.StdEncoding.DecodeString(strings.TrimSpace(req.NonceB64))
	if nerr != nil {
		nonce, nerr = base64.URLEncoding.DecodeString(strings.TrimSpace(req.NonceB64))
	}
	if nerr != nil || len(nonce) == 0 || len(nonce) > 64 {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "nonce_b64 required, 1-64 bytes", false)
		return
	}
	if req.DecidedAtMillis <= 0 {
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, "decided_at_millis required", false)
		return
	}
	nowMillis := s.now().UnixMilli()
	rec := &calcarv1.AuthorizationRecord{
		AuthorizationId:  strings.TrimSpace(req.AuthorizationID),
		SessionId:        sessionID,
		SubjectDeviceId:  &calcarv1.DeviceId{Value: subjectDeviceID},
		SubjectPublicKey: subjectPub,
		OwnerDeviceId:    &calcarv1.DeviceId{Value: me.ID},
		ContextHash:      trust.ContextHash(sess.JoinName, sess.JoinFingerprint, subjectDeviceID, sessionID, requestedAtProxy(sess)),
		OwnerSignature:   sig,
		DecidedAtMillis:  req.DecidedAtMillis,
		Nonce:            nonce,
	}
	// The Owner public key is the caller's registered key: verification
	// uses stored keys only, never a test signer.
	if verr := trust.VerifyAuthorization(rec, ed25519.PublicKey(me.PubKey), sessionID, sess.JoinPubKey, rec.ContextHash, nowMillis, trust.PairingTTLMillis); verr != nil {
		s.writeTrustErr(w, verr)
		return
	}
	// Grant persistence is owned by DecidePairingSession (seam contract:
	// atomically consume the session and record the grant on approve).
	// The api layer must NOT also call RecordGrant on this path.
	if derr := s.st.DecidePairingSession(ctx, sessionID, true, subjectPub, sig, me.ID); derr != nil {
		storeErr(w, derr, trust.CodePairingExpired, trust.CodePairingConsumed)
		return
	}
	comp := store.Device{
		ID:           subjectDeviceID,
		UserID:       sess.UserID,
		Role:         store.RoleComputer,
		DisplayName:  sess.JoinName,
		PubKey:       subjectPub,
		Fingerprint:  sess.JoinFingerprint,
		AuthorizedBy: me.ID,
	}
	if rerr := s.st.RegisterDevice(ctx, comp); rerr != nil && !errors.Is(rerr, store.ErrConflict) {
		// Session is consumed with the grant recorded; surfacing 500 is
		// honest, the computer re-pairs only if its row is truly absent.
		writeErr(w, http.StatusInternalServerError, "STORE_ERROR", "computer registration failed", true)
		return
	}
	s.hub.Notify(ws.Event{UserID: sess.UserID, Type: ws.EventPairingDecided,
		Payload: map[string]any{"session_id": sessionID, "approved": true, "subject_device_id": subjectDeviceID}})
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": sessionID, "status": store.SessionApproved,
		"subject_device_id": subjectDeviceID,
	})
}

// writeTrustErr maps trust verification codes to transport statuses.
func (s *Server) writeTrustErr(w http.ResponseWriter, verr error) {
	switch trust.ErrorCode(verr) {
	case trust.CodePairingExpired:
		writeErr(w, http.StatusGone, trust.CodePairingExpired, verr.Error(), false)
	case trust.CodePubkeyMismatch:
		writeErr(w, http.StatusUnprocessableEntity, trust.CodePubkeyMismatch, verr.Error(), false)
	case trust.CodeReplayedID:
		writeErr(w, http.StatusConflict, trust.CodeReplayedID, verr.Error(), false)
	case trust.CodeUnknownSession:
		writeErr(w, http.StatusNotFound, trust.CodeUnknownSession, verr.Error(), false)
	case trust.CodeBadSignature:
		writeErr(w, http.StatusUnauthorized, trust.CodeBadSignature, verr.Error(), false)
	default:
		writeErr(w, http.StatusBadRequest, trust.CodeInvalidInput, verr.Error(), false)
	}
}
