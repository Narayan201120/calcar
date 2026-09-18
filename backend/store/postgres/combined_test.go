// Unit tests for the combined store routing in backend/store/combined.go.
// Fakes stand in for the Postgres and Redis halves so no server is needed.
package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/calcar/calcar/backend/store"
)

type fakeBackend struct {
	calls     []string
	getSess   store.PairingSession
	getErr    error
	submitErr error
	decideErr error
	userID    string
	token     string
}

func (f *fakeBackend) note(call string) { f.calls = append(f.calls, call) }
func (f *fakeBackend) called(call string) bool {
	for _, c := range f.calls {
		if c == call {
			return true
		}
	}
	return false
}

func (f *fakeBackend) CreateUser(ctx context.Context) (string, error) {
	f.note("CreateUser")
	return f.userID, nil
}
func (f *fakeBackend) RegisterDevice(ctx context.Context, d store.Device) error {
	f.note("RegisterDevice")
	return nil
}
func (f *fakeBackend) GetDevice(ctx context.Context, id string) (store.Device, error) {
	f.note("GetDevice")
	return store.Device{ID: id}, nil
}
func (f *fakeBackend) ListUserDevices(ctx context.Context, userID string) ([]store.Device, error) {
	f.note("ListUserDevices")
	return nil, nil
}
func (f *fakeBackend) RevokeDevice(ctx context.Context, id, revokedBy, reason string) error {
	f.note("RevokeDevice")
	return nil
}
func (f *fakeBackend) IsRevoked(ctx context.Context, deviceID string) (bool, error) {
	f.note("IsRevoked")
	return false, nil
}
func (f *fakeBackend) CreatePairingSession(ctx context.Context, s store.PairingSession) error {
	f.note("CreatePairingSession")
	return nil
}
func (f *fakeBackend) GetPairingSession(ctx context.Context, id string) (store.PairingSession, error) {
	f.note("GetPairingSession")
	return f.getSess, f.getErr
}
func (f *fakeBackend) SubmitJoinRequest(ctx context.Context, sessionID string, pubKey []byte, fingerprint, displayName, requestID string) error {
	f.note("SubmitJoinRequest")
	return f.submitErr
}
func (f *fakeBackend) DecidePairingSession(ctx context.Context, sessionID string, approve bool, subjectPubKey, granterSig []byte, granterDeviceID string) error {
	f.note("DecidePairingSession")
	return f.decideErr
}
func (f *fakeBackend) RecordGrant(ctx context.Context, g store.TrustGrant) error {
	f.note("RecordGrant")
	return nil
}
func (f *fakeBackend) IssueChallenge(ctx context.Context, deviceID string) (string, error) {
	f.note("IssueChallenge")
	return "ch", nil
}
func (f *fakeBackend) ConsumeChallenge(ctx context.Context, deviceID, challenge string) error {
	f.note("ConsumeChallenge")
	return nil
}
func (f *fakeBackend) IssueAccessToken(ctx context.Context, deviceID, userID string, ttl time.Duration) (string, error) {
	f.note("IssueAccessToken")
	return f.token, nil
}
func (f *fakeBackend) ResolveAccessToken(ctx context.Context, token string) (string, string, error) {
	f.note("ResolveAccessToken")
	return "d", "u", nil
}
func (f *fakeBackend) RevokeDeviceTokens(ctx context.Context, deviceID string) error {
	f.note("RevokeDeviceTokens")
	return nil
}
func (f *fakeBackend) SetPresence(ctx context.Context, p store.Presence) error {
	f.note("SetPresence")
	return nil
}
func (f *fakeBackend) GetPresence(ctx context.Context, deviceID string) (store.Presence, error) {
	f.note("GetPresence")
	return store.Presence{DeviceID: deviceID}, f.getErr
}
func (f *fakeBackend) SetPushToken(ctx context.Context, deviceID, platform, token string) error {
	f.note("SetPushToken")
	return nil
}
func (f *fakeBackend) EnqueueAttention(ctx context.Context, userID string, a store.Attention) error {
	f.note("EnqueueAttention")
	return nil
}
func (f *fakeBackend) CheckAndMarkRequest(ctx context.Context, requestID string, ttl time.Duration) error {
	f.note("CheckAndMarkRequest")
	return nil
}
func (f *fakeBackend) Ping(ctx context.Context) error {
	f.note("Ping")
	return nil
}

// fakeLatch adds the Redis single-use latch surface.
type fakeLatch struct {
	*fakeBackend
	liveErr error
	marked  []string
}

func (f *fakeLatch) CheckPairingLive(ctx context.Context, id string) error { return f.liveErr }
func (f *fakeLatch) MarkPairingConsumed(ctx context.Context, id, status string) error {
	f.marked = append(f.marked, status)
	return nil
}

func TestCombinedRoutesDurableToPG(t *testing.T) {
	pg, rd := &fakeBackend{userID: "u1"}, &fakeBackend{}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	if _, err := c.CreateUser(ctx); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		call func() error
	}{
		{"RegisterDevice", func() error { return c.RegisterDevice(ctx, store.Device{}) }},
		{"RevokeDevice", func() error { return c.RevokeDevice(ctx, "d", "o", "r") }},
		{"IsRevoked", func() error { _, err := c.IsRevoked(ctx, "d"); return err }},
		{"RecordGrant", func() error { return c.RecordGrant(ctx, store.TrustGrant{}) }},
	} {
		if err := tc.call(); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if !pg.called(tc.name) {
			t.Errorf("%s did not reach pg", tc.name)
		}
		if rd.called(tc.name) {
			t.Errorf("%s leaked to rd", tc.name)
		}
	}
}

func TestCombinedRoutesEphemeralToRedis(t *testing.T) {
	pg, rd := &fakeBackend{}, &fakeBackend{token: "tok"}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	calls := []struct {
		name string
		call func() error
	}{
		{"IssueChallenge", func() error { _, err := c.IssueChallenge(ctx, "d"); return err }},
		{"ConsumeChallenge", func() error { return c.ConsumeChallenge(ctx, "d", "c") }},
		{"IssueAccessToken", func() error { _, err := c.IssueAccessToken(ctx, "d", "u", time.Minute); return err }},
		{"ResolveAccessToken", func() error { _, _, err := c.ResolveAccessToken(ctx, "t"); return err }},
		{"RevokeDeviceTokens", func() error { return c.RevokeDeviceTokens(ctx, "d") }},
		{"EnqueueAttention", func() error { return c.EnqueueAttention(ctx, "u", store.Attention{}) }},
		{"CheckAndMarkRequest", func() error { return c.CheckAndMarkRequest(ctx, "r", time.Minute) }},
	}
	for _, tc := range calls {
		if err := tc.call(); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if !rd.called(tc.name) {
			t.Errorf("%s did not reach rd", tc.name)
		}
		if pg.called(tc.name) {
			t.Errorf("%s leaked to pg", tc.name)
		}
	}
}

func TestCombinedDecideMarksConsumedOnApprove(t *testing.T) {
	pg := &fakeBackend{}
	rd := &fakeLatch{fakeBackend: &fakeBackend{}}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	if err := c.DecidePairingSession(ctx, "s", true, []byte{1}, []byte{2}, "owner"); err != nil {
		t.Fatalf("decide: %v", err)
	}
	if !pg.called("DecidePairingSession") {
		t.Error("decide did not reach pg")
	}
	if len(rd.marked) != 1 || rd.marked[0] != store.SessionApproved {
		t.Errorf("marked = %v, want [%s]", rd.marked, store.SessionApproved)
	}
}

func TestCombinedDecideCompensatesOnPGFailure(t *testing.T) {
	pg := &fakeBackend{decideErr: store.ErrExpired}
	rd := &fakeLatch{fakeBackend: &fakeBackend{}}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	err := c.DecidePairingSession(ctx, "s", true, []byte{1}, []byte{2}, "owner")
	if !errors.Is(err, store.ErrExpired) {
		t.Fatalf("err = %v, want ErrExpired", err)
	}
	if len(rd.marked) != 1 || rd.marked[0] != store.SessionConsumed {
		t.Errorf("compensating mark = %v, want [%s]", rd.marked, store.SessionConsumed)
	}
}

func TestCombinedDecideBlockedByLatch(t *testing.T) {
	pg := &fakeBackend{}
	rd := &fakeLatch{fakeBackend: &fakeBackend{}, liveErr: store.ErrGone}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	if err := c.DecidePairingSession(ctx, "s", true, []byte{1}, []byte{2}, "owner"); !errors.Is(err, store.ErrGone) {
		t.Fatalf("err = %v, want ErrGone", err)
	}
	if pg.called("DecidePairingSession") {
		t.Error("consumed latch must block before pg")
	}
}

func TestCombinedDecideWithoutLatchStillWorks(t *testing.T) {
	pg := &fakeBackend{}
	rd := &fakeBackend{} // no latch methods
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	if err := c.DecidePairingSession(ctx, "s", false, nil, nil, "owner"); err != nil {
		t.Fatalf("decide: %v", err)
	}
	if !pg.called("DecidePairingSession") {
		t.Error("decide did not reach pg")
	}
}

func TestCombinedGetFallsBackToPG(t *testing.T) {
	want := store.PairingSession{ID: "s", Status: store.SessionExpired}
	pg := &fakeBackend{getSess: want}
	rd := &fakeBackend{getErr: store.ErrNotFound}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	got, err := c.GetPairingSession(ctx, "s")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Status != store.SessionExpired {
		t.Errorf("status = %q, want expired", got.Status)
	}
}

func TestCombinedSubmitJoinFallsBackToPG(t *testing.T) {
	pg := &fakeBackend{submitErr: store.ErrExpired}
	rd := &fakeBackend{submitErr: store.ErrNotFound}
	c := store.NewStore(pg, rd)
	ctx := context.Background()

	err := c.SubmitJoinRequest(ctx, "s", []byte{1}, "fp", "pc", "req")
	if !errors.Is(err, store.ErrExpired) {
		t.Fatalf("err = %v, want ErrExpired from pg arbitration", err)
	}
}

func TestCombinedPingChecksBoth(t *testing.T) {
	pg, rd := &fakeBackend{}, &fakeBackend{}
	c := store.NewStore(pg, rd)
	if err := c.Ping(context.Background()); err != nil {
		t.Fatalf("ping: %v", err)
	}
	if !pg.called("Ping") || !rd.called("Ping") {
		t.Errorf("ping must hit both backends (pg=%v rd=%v)", pg.called("Ping"), rd.called("Ping"))
	}
}
