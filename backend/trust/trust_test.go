package trust_test

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	calcarv1 "github.com/calcar/calcar/backend/gen/calcar/v1"
	"github.com/calcar/calcar/backend/trust"
)

type vectorRecord struct {
	AuthorizationID   string `json:"authorization_id"`
	SessionID         string `json:"session_id"`
	SubjectDeviceID   string `json:"subject_device_id"`
	SubjectPublicKey  string `json:"subject_public_key_hex"`
	OwnerDeviceID     string `json:"owner_device_id"`
	DisplayName       string `json:"display_name"`
	RequestedAtMillis int64  `json:"requested_at_millis"`
	ContextHash       string `json:"context_hash_hex"`
	DecidedAtMillis   int64  `json:"decided_at_millis"`
	Nonce             string `json:"nonce_hex"`
	SigningPayloadHex string `json:"signing_payload_hex"`
	OwnerSignatureHex string `json:"owner_signature_hex"`
}

type vectors struct {
	OwnerSeedHex      string       `json:"owner_seed_hex"`
	OwnerPublicKeyHex string       `json:"owner_public_key_hex"`
	ComputerSeedHex   string       `json:"computer_seed_hex"`
	ComputerPubHex    string       `json:"computer_public_key_hex"`
	ComputerFP        string       `json:"computer_fingerprint"`
	ComputerDeviceID  string       `json:"computer_device_id"`
	AuthRecord        vectorRecord `json:"authorization_record"`
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex: %v", err)
	}
	return b
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	return v
}

func vectorKeys(t *testing.T, v vectors) (ownerPriv ed25519.PrivateKey, ownerPub, compPub ed25519.PublicKey) {
	t.Helper()
	ownerPriv = ed25519.NewKeyFromSeed(mustHex(t, v.OwnerSeedHex))
	ownerPub = ownerPriv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(ownerPub); got != v.OwnerPublicKeyHex {
		t.Fatalf("owner pub mismatch:\n got %s\nwant %s", got, v.OwnerPublicKeyHex)
	}
	compPub = ed25519.NewKeyFromSeed(mustHex(t, v.ComputerSeedHex)).Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(compPub); got != v.ComputerPubHex {
		t.Fatalf("computer pub mismatch:\n got %s\nwant %s", got, v.ComputerPubHex)
	}
	return ownerPriv, ownerPub, compPub
}

func buildVectorRecord(t *testing.T, v vectors) *calcarv1.AuthorizationRecord {
	t.Helper()
	return &calcarv1.AuthorizationRecord{
		AuthorizationId:  v.AuthRecord.AuthorizationID,
		SessionId:        v.AuthRecord.SessionID,
		SubjectDeviceId:  &calcarv1.DeviceId{Value: v.AuthRecord.SubjectDeviceID},
		SubjectPublicKey: mustHex(t, v.AuthRecord.SubjectPublicKey),
		OwnerDeviceId:    &calcarv1.DeviceId{Value: v.AuthRecord.OwnerDeviceID},
		ContextHash:      mustHex(t, v.AuthRecord.ContextHash),
		OwnerSignature:   mustHex(t, v.AuthRecord.OwnerSignatureHex),
		DecidedAtMillis:  v.AuthRecord.DecidedAtMillis,
		Nonce:            mustHex(t, v.AuthRecord.Nonce),
	}
}

func checkCode(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want error %s, got nil", want)
	}
	if got := trust.ErrorCode(err); got != want {
		t.Fatalf("want code %s, got %s (%v)", want, got, err)
	}
}

// Golden fingerprint and device id pinned by vectors.json.
func TestGoldenFingerprintAndDeviceID(t *testing.T) {
	v := loadVectors(t)
	_, _, compPub := vectorKeys(t, v)

	fp, err := trust.FingerprintEd25519Pub(compPub)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	if fp != v.ComputerFP {
		t.Fatalf("fingerprint mismatch:\n got %s\nwant %s", fp, v.ComputerFP)
	}
	if fp != "24F6 ED6A CBFE 1009 C030 D7CA 567C 33CA 4830 9114 9823 6B55 61A6 C82A BEC5 DE28" {
		t.Fatalf("golden fingerprint drift: %s", fp)
	}

	did, err := trust.DeviceIDForComputer(compPub)
	if err != nil {
		t.Fatalf("device id: %v", err)
	}
	if did != v.ComputerDeviceID || did != "RD-WIN-24F6ED6A" {
		t.Fatalf("device id mismatch: got %s want %s", did, v.ComputerDeviceID)
	}

	if _, err := trust.FingerprintEd25519Pub([]byte("short")); err == nil {
		t.Fatal("want error for short pubkey")
	}
	if _, err := trust.DeviceIDForComputer(nil); err == nil {
		t.Fatal("want error for nil pubkey")
	}
}

// Committed deterministic bytes and signature verify against the Owner key.
func TestVectorSignatureVerifies(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, compPub := vectorKeys(t, v)
	rec := buildVectorRecord(t, v)

	payload, err := trust.SigningPayload(rec)
	if err != nil {
		t.Fatalf("payload: %v", err)
	}
	if got := hex.EncodeToString(payload); got != v.AuthRecord.SigningPayloadHex {
		t.Fatalf("payload drift:\n got %s\nwant %s", got, v.AuthRecord.SigningPayloadHex)
	}
	if !ed25519.Verify(ownerPub, payload, rec.GetOwnerSignature()) {
		t.Fatal("raw ed25519 verify of vector signature failed")
	}
	ctx := trust.ContextHash(v.AuthRecord.DisplayName, v.ComputerFP, v.ComputerDeviceID, v.AuthRecord.SessionID, v.AuthRecord.RequestedAtMillis)
	if hex.EncodeToString(ctx) != v.AuthRecord.ContextHash {
		t.Fatal("context hash recompute mismatch")
	}
	err = trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, compPub, ctx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	if err != nil {
		t.Fatalf("vector authorization rejected: %v", err)
	}
}

// Happy approve: live session, fresh request id, valid grant, single consume.
func TestHappyApprove(t *testing.T) {
	v := loadVectors(t)
	ownerPriv, ownerPub, compPub := vectorKeys(t, v)
	now := v.AuthRecord.DecidedAtMillis

	store := trust.NewSessionStore()
	sess := trust.NewSession("sess-happy-1", "owner-phone-vector-01", now-trust.PairingTTLMillis/2, now+trust.PairingTTLMillis/2)
	if err := store.Add(sess); err != nil {
		t.Fatalf("store add: %v", err)
	}
	got, err := store.Get("sess-happy-1")
	if err != nil || got != sess {
		t.Fatalf("store get: %v", err)
	}
	if err := sess.CheckLive(now); err != nil {
		t.Fatalf("live session rejected: %v", err)
	}

	seen := trust.NewSeenIDs()
	if err := seen.Add("req-happy-1", now, trust.PairingTTLMillis); err != nil {
		t.Fatalf("first request id rejected: %v", err)
	}

	fp, _ := trust.FingerprintEd25519Pub(compPub)
	did, _ := trust.DeviceIDForComputer(compPub)
	ctx := trust.ContextHash("Narayan-PC", fp, did, sess.ID, now)
	rec := &calcarv1.AuthorizationRecord{
		AuthorizationId:  "auth-happy-1",
		SessionId:        sess.ID,
		SubjectDeviceId:  &calcarv1.DeviceId{Value: did},
		SubjectPublicKey: compPub,
		OwnerDeviceId:    &calcarv1.DeviceId{Value: "owner-phone-vector-01"},
		ContextHash:      ctx,
		DecidedAtMillis:  now,
		Nonce:            bytes.Repeat([]byte{0x07}, 16),
	}
	if _, err := trust.SignAuthorizationForTest(ownerPriv, rec); err != nil {
		t.Fatalf("sign: %v", err)
	}
	if err := trust.VerifyAuthorization(rec, ownerPub, sess.ID, compPub, ctx, now, trust.PairingTTLMillis); err != nil {
		t.Fatalf("happy authorization rejected: %v", err)
	}
	if err := sess.Approve(); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if err := sess.Consume(); err != nil {
		t.Fatalf("consume: %v", err)
	}
	if err := sess.CheckLive(now); err == nil {
		t.Fatal("consumed session still live")
	}
}

// Expired session join fails; old grant fails TTL.
func TestExpiredSessionRejected(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, compPub := vectorKeys(t, v)
	now := v.AuthRecord.DecidedAtMillis

	sess := trust.NewSession("sess-old", "owner", now-2*trust.PairingTTLMillis, now-trust.PairingTTLMillis)
	checkCode(t, sess.CheckLive(now), trust.CodePairingExpired)

	rec := buildVectorRecord(t, v)
	ctx := mustHex(t, v.AuthRecord.ContextHash)
	err := trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, compPub, ctx,
		v.AuthRecord.DecidedAtMillis+trust.PairingTTLMillis+1, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodePairingExpired)
}

// Double approve fails; nothing is decided twice.
func TestDoubleApproveRejected(t *testing.T) {
	sess := trust.NewSession("sess-double", "owner", 1000, 1000+trust.PairingTTLMillis)
	if err := sess.Approve(); err != nil {
		t.Fatalf("first approve: %v", err)
	}
	checkCode(t, sess.Approve(), trust.CodePairingConsumed)
	if err := sess.Consume(); err != nil {
		t.Fatalf("consume: %v", err)
	}
	checkCode(t, sess.Approve(), trust.CodePairingConsumed)
	checkCode(t, sess.Reject(), trust.CodePairingConsumed)
	checkCode(t, sess.Consume(), trust.CodePairingConsumed)
}

// Grant bound to key A never validates against key B.
func TestSwappedPubkeyRejected(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, _ := vectorKeys(t, v)
	rec := buildVectorRecord(t, v)
	ctx := mustHex(t, v.AuthRecord.ContextHash)

	otherPub := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x40}, 32)).Public().(ed25519.PublicKey)
	err := trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, otherPub, ctx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodePubkeyMismatch)
}

// Flipped signature bit fails.
func TestSpoofedSignatureRejected(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, compPub := vectorKeys(t, v)
	rec := buildVectorRecord(t, v)
	ctx := mustHex(t, v.AuthRecord.ContextHash)
	rec.OwnerSignature[0] ^= 0x01

	err := trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, compPub, ctx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodeBadSignature)
}

// Unknown session ids fail closed.
func TestUnknownSessionRejected(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, compPub := vectorKeys(t, v)
	store := trust.NewSessionStore()
	if _, err := store.Get("sess-missing"); err == nil {
		t.Fatal("unknown session accepted")
	} else {
		checkCode(t, err, trust.CodeUnknownSession)
	}

	rec := buildVectorRecord(t, v)
	ctx := mustHex(t, v.AuthRecord.ContextHash)
	err := trust.VerifyAuthorization(rec, ownerPub, "sess-missing", compPub, ctx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodeUnknownSession)
}

// Attacker PC key cannot stand in for the Owner key.
func TestNonOwnerSignatureRejected(t *testing.T) {
	v := loadVectors(t)
	_, _, compPub := vectorKeys(t, v)
	compPriv := ed25519.NewKeyFromSeed(mustHex(t, v.ComputerSeedHex))
	rec := buildVectorRecord(t, v)
	rec.OwnerSignature = nil
	if _, err := trust.SignAuthorizationForTest(compPriv, rec); err != nil {
		t.Fatalf("attacker sign: %v", err)
	}
	ownerPub := ed25519.NewKeyFromSeed(mustHex(t, v.OwnerSeedHex)).Public().(ed25519.PublicKey)
	ctx := mustHex(t, v.AuthRecord.ContextHash)
	err := trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, compPub, ctx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodeBadSignature)
}

// Wrong human context fails even with a valid Owner signature shape.
func TestTamperedContextRejected(t *testing.T) {
	v := loadVectors(t)
	_, ownerPub, compPub := vectorKeys(t, v)
	rec := buildVectorRecord(t, v)
	wrongCtx := bytes.Repeat([]byte{0xBB}, 32)
	err := trust.VerifyAuthorization(rec, ownerPub, v.AuthRecord.SessionID, compPub, wrongCtx,
		v.AuthRecord.DecidedAtMillis, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodePubkeyMismatch)
}

// Future-skewed decision fails.
func TestFutureSkewRejected(t *testing.T) {
	v := loadVectors(t)
	ownerPriv, ownerPub, compPub := vectorKeys(t, v)
	now := v.AuthRecord.DecidedAtMillis
	fp, _ := trust.FingerprintEd25519Pub(compPub)
	did, _ := trust.DeviceIDForComputer(compPub)
	ctx := trust.ContextHash("Narayan-PC", fp, did, "sess-skew", now)
	rec := &calcarv1.AuthorizationRecord{
		AuthorizationId:  "auth-skew",
		SessionId:        "sess-skew",
		SubjectDeviceId:  &calcarv1.DeviceId{Value: did},
		SubjectPublicKey: compPub,
		OwnerDeviceId:    &calcarv1.DeviceId{Value: "owner"},
		ContextHash:      ctx,
		DecidedAtMillis:  now + trust.MaxClockSkewMillis + 1,
		Nonce:            bytes.Repeat([]byte{0x09}, 16),
	}
	if _, err := trust.SignAuthorizationForTest(ownerPriv, rec); err != nil {
		t.Fatalf("sign: %v", err)
	}
	err := trust.VerifyAuthorization(rec, ownerPub, "sess-skew", compPub, ctx, now, trust.PairingTTLMillis)
	checkCode(t, err, trust.CodeReplayedID)
}

// First resolve wins; late duplicates fail.
func TestApprovalDoubleResolveRejected(t *testing.T) {
	r := trust.NewApprovalRegistry()
	if err := r.Create("appr-1", 5000); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := r.Resolve("appr-1", calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW, 1000); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	st, ok := r.State("appr-1")
	if !ok || st != calcarv1.ApprovalState_APPROVAL_STATE_APPROVED {
		t.Fatalf("state after allow: %v %v", st, ok)
	}
	checkCode(t, r.Resolve("appr-1", calcarv1.ApprovalDecision_APPROVAL_DECISION_REJECT, 2000), trust.CodeApprovalResolved)
	checkCode(t, r.Resolve("appr-1", calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW, 2000), trust.CodeApprovalResolved)
	if err := r.Resolve("appr-missing", calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW, 1000); err == nil {
		t.Fatal("unknown approval accepted")
	} else {
		checkCode(t, err, trust.CodeUnknownApproval)
	}
}

// Resolve past expiry latches expired and fails.
func TestExpiredApprovalRejected(t *testing.T) {
	r := trust.NewApprovalRegistry()
	if err := r.Create("appr-old", 2000); err != nil {
		t.Fatalf("create: %v", err)
	}
	checkCode(t, r.Resolve("appr-old", calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW, 2000), trust.CodeApprovalExpired)
	st, _ := r.State("appr-old")
	if st != calcarv1.ApprovalState_APPROVAL_STATE_EXPIRED {
		t.Fatalf("want expired, got %v", st)
	}
	checkCode(t, r.Resolve("appr-old", calcarv1.ApprovalDecision_APPROVAL_DECISION_ALLOW, 3000), trust.CodeApprovalResolved)
}

// Reused request id fails; reuse after TTL passes.
func TestReplayedRequestIDRejected(t *testing.T) {
	c := trust.NewSeenIDs()
	if err := c.Add("req-1", 1000, 5000); err != nil {
		t.Fatalf("first add: %v", err)
	}
	if !c.Seen("req-1", 2000) {
		t.Fatal("id should be seen inside TTL")
	}
	checkCode(t, c.Add("req-1", 2000, 5000), trust.CodeReplayedID)
	if err := c.Add("req-1", 6000, 5000); err != nil {
		t.Fatalf("reuse after TTL should pass: %v", err)
	}
	c.Purge(20000)
	if c.Seen("req-1", 20000) {
		t.Fatal("purged id still seen")
	}
	if err := c.Add("", 1000, 5000); err == nil {
		t.Fatal("empty id accepted")
	}
}

// Reject, expire, and consume latch the session exactly once.
func TestSessionTransitions(t *testing.T) {
	base := int64(100000)

	r := trust.NewSession("s-reject", "owner", base, base+trust.PairingTTLMillis)
	if err := r.Reject(); err != nil {
		t.Fatalf("reject: %v", err)
	}
	checkCode(t, r.Reject(), trust.CodePairingConsumed)
	checkCode(t, r.Approve(), trust.CodePairingConsumed)
	if err := r.Consume(); err != nil {
		t.Fatalf("consume after reject: %v", err)
	}

	e := trust.NewSession("s-expire", "owner", base, base+trust.PairingTTLMillis)
	if err := e.Expire(); err != nil {
		t.Fatalf("expire: %v", err)
	}
	checkCode(t, e.Expire(), trust.CodePairingExpired)
	checkCode(t, e.Approve(), trust.CodePairingExpired)
	checkCode(t, e.CheckLive(base+1), trust.CodePairingExpired)

	store := trust.NewSessionStore()
	if err := store.Add(r); err != nil {
		t.Fatalf("store add: %v", err)
	}
	checkCode(t, store.Add(r), trust.CodeReplayedID)
	if err := store.Add(nil); err == nil {
		t.Fatal("nil session accepted")
	}
}
