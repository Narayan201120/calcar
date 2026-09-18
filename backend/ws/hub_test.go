package ws

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/calcar/calcar/backend/store"
)

var _ store.Store = (*wsfake)(nil)

type wsfake struct {
	mu       sync.Mutex
	devices  map[string]store.Device
	tokens   map[string][2]string // token -> device,user
	presence map[string]store.Presence
	catchups int
}

func newWSFake() *wsfake {
	return &wsfake{devices: make(map[string]store.Device), tokens: make(map[string][2]string), presence: make(map[string]store.Presence)}
}

func (f *wsfake) addDevice(deviceID, userID, role string, revoked bool, token string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.devices[deviceID] = store.Device{ID: deviceID, UserID: userID, Role: role, Revoked: revoked}
	f.tokens[token] = [2]string{deviceID, userID}
}

func (f *wsfake) ResolveAccessToken(_ context.Context, token string) (string, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if du, ok := f.tokens[token]; ok {
		return du[0], du[1], nil
	}
	return "", "", store.ErrNotFound
}

func (f *wsfake) GetDevice(_ context.Context, id string) (store.Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.devices[id]
	if !ok {
		return store.Device{}, store.ErrNotFound
	}
	return d, nil
}

func (f *wsfake) IsRevoked(_ context.Context, deviceID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.devices[deviceID]
	if !ok {
		return false, store.ErrNotFound
	}
	return d.Revoked, nil
}

func (f *wsfake) SetPresence(_ context.Context, p store.Presence) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.presence[p.DeviceID] = p
	return nil
}

func (f *wsfake) GetPresence(_ context.Context, deviceID string) (store.Presence, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p, ok := f.presence[deviceID]
	if !ok {
		return store.Presence{}, store.ErrNotFound
	}
	return p, nil
}

func (f *wsfake) EnqueueAttention(_ context.Context, _ string, _ store.Attention) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.catchups++
	return nil
}

func (f *wsfake) CreateUser(_ context.Context) (string, error) { return "user-1", nil }
func (f *wsfake) RegisterDevice(_ context.Context, _ store.Device) error {
	return store.ErrConflict
}
func (f *wsfake) ListUserDevices(_ context.Context, _ string) ([]store.Device, error) {
	return nil, nil
}
func (f *wsfake) RevokeDevice(_ context.Context, _, _, _ string) error { return nil }
func (f *wsfake) CreatePairingSession(_ context.Context, _ store.PairingSession) error {
	return nil
}
func (f *wsfake) GetPairingSession(_ context.Context, _ string) (store.PairingSession, error) {
	return store.PairingSession{}, store.ErrNotFound
}
func (f *wsfake) SubmitJoinRequest(_ context.Context, _ string, _ []byte, _, _, _ string) error {
	return nil
}
func (f *wsfake) DecidePairingSession(_ context.Context, _ string, _ bool, _ []byte, _ []byte, _ string) error {
	return nil
}
func (f *wsfake) RecordGrant(_ context.Context, _ store.TrustGrant) error { return nil }
func (f *wsfake) IssueChallenge(_ context.Context, _ string) (string, error) {
	return "", store.ErrNotFound
}
func (f *wsfake) ConsumeChallenge(_ context.Context, _, _ string) error { return nil }
func (f *wsfake) IssueAccessToken(_ context.Context, _, _ string, _ time.Duration) (string, error) {
	return "", nil
}
func (f *wsfake) RevokeDeviceTokens(_ context.Context, _ string) error { return nil }
func (f *wsfake) SetPushToken(_ context.Context, _, _, _ string) error { return nil }
func (f *wsfake) CheckAndMarkRequest(_ context.Context, _ string, _ time.Duration) error {
	return nil
}
func (f *wsfake) Ping(_ context.Context) error { return nil }

func dialWS(t *testing.T, url, token string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, url+"?access_token="+token, nil)
	if err != nil {
		if resp != nil {
			t.Fatalf("dial status=%d err=%v", resp.StatusCode, err)
		}
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = c.Close(websocket.StatusNormalClosure, "test done") })
	return c
}

func readUntil(t *testing.T, c *websocket.Conn, wantType string) Envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, raw, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		var env Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("bad envelope: %v", err)
		}
		if env.ProtocolVersion != ProtocolVersion {
			t.Fatalf("protocol_version = %q", env.ProtocolVersion)
		}
		if env.MsgID == "" {
			t.Fatal("envelope missing msg_id")
		}
		if env.Type == wantType {
			return env
		}
	}
}

func TestSubscribeReceivesDecided(t *testing.T) {
	f := newWSFake()
	f.addDevice("PH-1", "user-1", store.RoleOwnerPhone, false, "tok-owner")
	h := NewHub(f)
	h.SetHeartbeatInterval(100 * time.Millisecond)
	h.Go()
	defer h.Close()
	srv := httptest.NewServer(h)
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"

	c := dialWS(t, url, "tok-owner")
	// Keep the conn alive past the short test heartbeat windows.
	stopHB := make(chan struct{})
	defer close(stopHB)
	go func() {
		tick := time.NewTicker(30 * time.Millisecond)
		defer tick.Stop()
		ctx := context.Background()
		for {
			select {
			case <-tick.C:
				if err := c.Write(ctx, websocket.MessageText, []byte(`{"type":"heartbeat"}`)); err != nil {
					return
				}
			case <-stopHB:
				return
			}
		}
	}()
	// Auto-subscribed to the own-user topic; a decided event arrives.
	h.Notify(Event{UserID: "user-1", Type: EventPairingDecided,
		Payload: map[string]any{"session_id": "s-1", "approved": true}})
	env := readUntil(t, c, EventPairingDecided)
	if env.To != "user:user-1" {
		t.Fatalf("to = %q", env.To)
	}
	pl, _ := env.Payload.(map[string]any)
	if pl["session_id"] != "s-1" {
		t.Fatalf("payload = %v", env.Payload)
	}
	// Events for other users never arrive: only a heartbeat shows up.
	h.Notify(Event{UserID: "user-2", Type: EventPairingDecided,
		Payload: map[string]any{"session_id": "s-2"}})
	env = readUntil(t, c, EventHeartbeat)
	if env.Type != EventHeartbeat {
		t.Fatalf("leaked cross-user event: %v", env)
	}
}

func TestHeartbeatDropAfterMissed(t *testing.T) {
	f := newWSFake()
	f.addDevice("PH-1", "user-1", store.RoleOwnerPhone, false, "tok-owner")
	h := NewHub(f)
	h.SetHeartbeatInterval(50 * time.Millisecond)
	h.Go()
	defer h.Close()
	srv := httptest.NewServer(h)
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"

	c := dialWS(t, url, "tok-owner")
	defer func() { _ = c.Close(websocket.StatusNormalClosure, "x") }()
	// Never send anything: 3 missed 50ms windows must drop the conn.
	deadline := time.Now().Add(3 * time.Second)
	for h.ConnCount() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("silent connection not dropped after 3 missed heartbeats")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestHeartbeatKeepsAlive(t *testing.T) {
	f := newWSFake()
	f.addDevice("PH-1", "user-1", store.RoleOwnerPhone, false, "tok-owner")
	h := NewHub(f)
	h.SetHeartbeatInterval(50 * time.Millisecond)
	h.Go()
	defer h.Close()
	srv := httptest.NewServer(h)
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"

	c := dialWS(t, url, "tok-owner")
	ctx := context.Background()
	stop := make(chan struct{})
	go func() {
		defer close(stop)
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-tick.C:
				_ = c.Write(ctx, websocket.MessageText, []byte(`{"type":"heartbeat"}`))
			case <-stop:
				return
			}
		}
	}()
	// Drain inbound so the writer never blocks.
	go func() {
		for {
			_, _, err := c.Read(ctx)
			if err != nil {
				return
			}
		}
	}()
	time.Sleep(400 * time.Millisecond) // ~8 windows, would drop a silent conn twice over
	if h.ConnCount() != 1 {
		t.Fatalf("live heartbeat conn dropped, count=%d", h.ConnCount())
	}
}

func TestRevokedWSRefused(t *testing.T) {
	f := newWSFake()
	f.addDevice("PC-9", "user-1", store.RoleComputer, true, "tok-revoked")
	h := NewHub(f)
	h.Go()
	defer h.Close()
	srv := httptest.NewServer(h)
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, url+"?access_token=tok-revoked", nil)
	if err == nil {
		t.Fatal("revoked device dial succeeded")
	}
	if resp == nil || (resp.StatusCode != http.StatusForbidden && resp.StatusCode != http.StatusUnauthorized) {
		t.Fatalf("revoked dial status = %v, want 401/403", resp)
	}
}

func TestOverflowDropsAndMarksCatchup(t *testing.T) {
	f := newWSFake()
	f.addDevice("PH-1", "user-1", store.RoleOwnerPhone, false, "tok-owner")
	h := NewHub(f)
	h.SetHeartbeatInterval(time.Hour) // keep liveness out of this test
	h.Go()
	defer h.Close()
	srv := httptest.NewServer(h)
	defer srv.Close()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/ws"

	c := dialWS(t, url, "tok-owner")
	defer func() { _ = c.Close(websocket.StatusNormalClosure, "x") }()
	time.Sleep(100 * time.Millisecond) // let presence/connect settle
	// Client never reads; large payloads fill socket + 64-deep buffer.
	big := strings.Repeat("x", 64*1024)
	for i := 0; i < 300; i++ {
		h.Notify(Event{UserID: "user-1", Type: EventAttentionPending,
			Payload: map[string]any{"blob": big, "seq": i}})
	}
	deadline := time.Now().Add(5 * time.Second)
	for h.DroppedFor("PH-1") == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no overflow drops recorded with an unread 64-deep buffer")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Catch-up marker enqueued best-effort.
	deadline = time.Now().Add(5 * time.Second)
	for {
		f.mu.Lock()
		n := f.catchups
		f.mu.Unlock()
		if n > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("overflow did not mark attention pending for catch-up")
		}
		time.Sleep(20 * time.Millisecond)
	}
	_ = c
}
