// Package ws is the P3 signal plane: WebSocket fan-out only.
//
// Phones and computers hold one connection each to receive server-sent
// events (pairing.join_requested, pairing.decided, attention.pending,
// presence.changed, trust.revoked). No state mutation rides the socket
// except subscribe scoping and heartbeat.
//
// Wire-up: the api server owns one Hub and routes GET /v1/ws to it, then
// calls Hub.Notify after each state change it commits. Delivery is
// in-process channels only; Redis pubsub is a later scaling step.
package ws

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"

	"github.com/calcar/calcar/backend/store"
)

// ProtocolVersion rides every envelope. Clients must ignore unknown
// fields and refuse unknown major versions.
const ProtocolVersion = "1.0"

// SendBufferSize bounds per-device queued outbound messages. Overflow
// drops the message and marks attention pending so the device catches
// up over the authenticated HTTP channel.
const SendBufferSize = 64

// Server-sent event types. Stable strings, additive only.
const (
	EventPairingJoinRequested = "pairing.join_requested"
	EventPairingDecided       = "pairing.decided"
	EventAttentionPending     = "attention.pending"
	EventPresenceChanged      = "presence.changed"
	EventTrustRevoked         = "trust.revoked"
	EventHeartbeat            = "heartbeat"
)

// Inbound client message types accepted on the socket.
const (
	InHeartbeat = "heartbeat"
	InPong      = "pong"
	InSubscribe = "subscribe"
)

// Event is one server-sent signal. UserID selects the topic (all conns
// of that user); To optionally narrows to one device id.
type Event struct {
	UserID  string
	To      string
	Type    string
	Payload any
}

// Envelope is the wire shape of every server-sent message.
type Envelope struct {
	ProtocolVersion string `json:"protocol_version"`
	MsgID           string `json:"msg_id"`
	Type            string `json:"type"`
	To              string `json:"to,omitempty"`
	Payload         any    `json:"payload,omitempty"`
}

type inbound struct {
	Type  string `json:"type"`
	Topic string `json:"topic"`
}

// NewID mints a 128-bit crypto-random hex id for envelopes and sessions.
func NewID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("ws: crypto rand unavailable: " + err.Error())
	}
	return hex.EncodeToString(b[:])
}

// NewUUIDv4 mints an RFC 4122 v4 UUID for session ids.
func NewUUIDv4() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("ws: crypto rand unavailable: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// NewNonceB64URL mints 128 random bits, base64url without padding.
func NewNonceB64URL() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("ws: crypto rand unavailable: " + err.Error())
	}
	return base64RawURL(b[:])
}

func base64RawURL(b []byte) string {
	const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	out := make([]byte, 0, 22)
	var acc uint
	var bits uint
	for _, c := range b {
		acc = (acc << 8) | uint(c)
		bits += 8
		for bits >= 6 {
			bits -= 6
			out = append(out, abc[(acc>>bits)&0x3F])
		}
	}
	if bits > 0 {
		out = append(out, abc[(acc<<(6-bits))&0x3F])
	}
	return string(out)
}

// Hub fans Events out to one-conn-per-device sockets.
type Hub struct {
	st store.Store

	mu       sync.Mutex
	byDevice map[string]*liveConn

	notifyCh chan Event
	closed   chan struct{}
	wg       sync.WaitGroup

	hbInterval time.Duration
	maxMissed  int

	logf func(string, ...any)
	now  func() time.Time
}

type liveConn struct {
	deviceID  string
	userID    string
	c         *websocket.Conn
	send      chan []byte
	lastSeen  atomic.Int64 // unix millis of last inbound message
	dropped   atomic.Int64 // overflow drops, for tests/metrics
	cancel    context.CancelFunc
	closeOnce sync.Once
}

// NewHub returns a Hub. Call Run or serve it via HTTP; Close stops it.
func NewHub(st store.Store) *Hub {
	return &Hub{
		st:         st,
		byDevice:   make(map[string]*liveConn),
		notifyCh:   make(chan Event, 1024),
		closed:     make(chan struct{}),
		hbInterval: 30 * time.Second,
		maxMissed:  3,
		logf:       log.Printf,
		now:        time.Now,
	}
}

// SetHeartbeatInterval overrides the 30s heartbeat (tests).
func (h *Hub) SetHeartbeatInterval(d time.Duration) { h.hbInterval = d }

// Run pumps Notify events until Close. ServeHTTP works without Run only
// if the caller drains notifications another way; normally main and the
// api server call Run once via Go.
func (h *Hub) Run() {
	h.wg.Add(1)
	go h.loop()
}

// Go is Run with a friendlier name for main.
func (h *Hub) Go() { h.Run() }

func (h *Hub) loop() {
	defer h.wg.Done()
	hb := time.NewTicker(h.hbInterval)
	defer hb.Stop()
	for {
		select {
		case <-h.closed:
			return
		case ev := <-h.notifyCh:
			h.fanout(ev)
		case <-hb.C:
			h.checkLiveness()
		}
	}
}

// Notify queues one event for fan-out. Non-blocking: a full queue drops
// the event and logs, fail-closed on delivery, never on callers.
func (h *Hub) Notify(ev Event) {
	select {
	case h.notifyCh <- ev:
	default:
		h.logf("ws: notify queue full, dropping type=%s user=%s", ev.Type, ev.UserID)
	}
}

// Close stops the hub and every live connection.
func (h *Hub) Close() {
	select {
	case <-h.closed:
		return
	default:
		close(h.closed)
	}
	h.mu.Lock()
	conns := make([]*liveConn, 0, len(h.byDevice))
	for _, lc := range h.byDevice {
		conns = append(conns, lc)
	}
	h.mu.Unlock()
	for _, lc := range conns {
		lc.close(websocket.StatusGoingAway, "hub closing")
	}
	h.wg.Wait()
}

// ConnCount reports live connections (tests/metrics).
func (h *Hub) ConnCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.byDevice)
}

// DroppedFor reports overflow drops for one device (tests/metrics).
func (h *Hub) DroppedFor(deviceID string) int64 {
	h.mu.Lock()
	lc := h.byDevice[deviceID]
	h.mu.Unlock()
	if lc == nil {
		return 0
	}
	return lc.dropped.Load()
}

func (h *Hub) fanout(ev Event) {
	env := Envelope{
		ProtocolVersion: ProtocolVersion,
		MsgID:           NewID(),
		Type:            ev.Type,
		To:              ev.To,
		Payload:         ev.Payload,
	}
	if env.To == "" {
		env.To = "user:" + ev.UserID
	}
	raw, err := json.Marshal(env)
	if err != nil {
		h.logf("ws: marshal event type=%s: %v", ev.Type, err)
		return
	}
	h.mu.Lock()
	targets := make([]*liveConn, 0, 1)
	for _, lc := range h.byDevice {
		if lc.userID != ev.UserID {
			continue
		}
		if ev.To != "" && lc.deviceID != ev.To {
			continue
		}
		targets = append(targets, lc)
	}
	h.mu.Unlock()
	for _, lc := range targets {
		select {
		case lc.send <- raw:
		default:
			lc.dropped.Add(1)
			h.markCatchup(lc, ev)
		}
	}
}

// markCatchup records an attention-pending hint so a device that lost
// messages refetches over authenticated HTTP. Best effort, async.
func (h *Hub) markCatchup(lc *liveConn, ev Event) {
	h.logf("ws: send buffer full device=%s, dropping type=%s", lc.deviceID, ev.Type)
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.st.EnqueueAttention(ctx, lc.userID, store.Attention{Kind: "catchup"})
	}()
}

// checkLiveness drops connections silent for maxMissed heartbeat windows.
func (h *Hub) checkLiveness() {
	cutoff := h.now().Add(-time.Duration(h.maxMissed) * h.hbInterval).UnixMilli()
	h.mu.Lock()
	stale := make([]*liveConn, 0)
	for _, lc := range h.byDevice {
		if lc.lastSeen.Load() < cutoff {
			stale = append(stale, lc)
		}
	}
	h.mu.Unlock()
	for _, lc := range stale {
		h.logf("ws: device=%s missed %d heartbeats, closing", lc.deviceID, h.maxMissed)
		lc.close(websocket.StatusPolicyViolation, "heartbeat missed")
	}
}

// ServeHTTP upgrades GET /v1/ws. Auth precedes the upgrade: Bearer
// token via Authorization header, ?access_token= query, or the
// Sec-WebSocket-Protocol value (last entry wins, "calcar-ws-v1"
// excluded). Revoked devices are refused before the handshake.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	token := bearerToken(r.Header.Get("Authorization"))
	if token == "" {
		token = r.URL.Query().Get("access_token")
	}
	if token == "" {
		token = protocolToken(r.Header.Get("Sec-WebSocket-Protocol"))
	}
	if token == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	deviceID, userID, err := h.st.ResolveAccessToken(ctx, token)
	cancel()
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}
	ctx2, cancel2 := context.WithTimeout(r.Context(), 10*time.Second)
	dev, gerr := h.st.GetDevice(ctx2, deviceID)
	cancel2()
	if gerr != nil {
		http.Error(w, "unknown device", http.StatusUnauthorized)
		return
	}
	if dev.Revoked {
		http.Error(w, "revoked", http.StatusForbidden)
		return
	}
	ctx3, cancel3 := context.WithTimeout(r.Context(), 10*time.Second)
	revoked, rerr := h.st.IsRevoked(ctx3, deviceID)
	cancel3()
	if rerr == nil && revoked {
		http.Error(w, "revoked", http.StatusForbidden)
		return
	}

	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols:   selectSubprotocol(r.Header.Get("Sec-WebSocket-Protocol")),
		OriginPatterns: []string{"*"}, // MVP behind Tailscale; tighten with pinned origin later.
	})
	if err != nil {
		h.logf("ws: accept device=%s: %v", deviceID, err)
		return
	}

	connCtx, connCancel := context.WithCancel(context.Background())
	lc := &liveConn{
		deviceID: deviceID,
		userID:   userID,
		c:        c,
		send:     make(chan []byte, SendBufferSize),
		cancel:   connCancel,
	}
	lc.lastSeen.Store(h.now().UnixMilli())

	h.mu.Lock()
	if old, dup := h.byDevice[deviceID]; dup {
		old.close(websocket.StatusPolicyViolation, "replaced by new connection")
	}
	h.byDevice[deviceID] = lc
	h.mu.Unlock()

	// Best-effort presence: online while the socket lives.
	_ = h.st.SetPresence(context.Background(), store.Presence{
		DeviceID: deviceID, Online: true, ConnID: NewID(), LastSeen: h.now(),
	})

	h.wg.Add(2)
	go h.readLoop(connCtx, lc)
	go h.writeLoop(connCtx, lc)

	<-connCtx.Done()
	h.mu.Lock()
	if h.byDevice[deviceID] == lc {
		delete(h.byDevice, deviceID)
	}
	h.mu.Unlock()
	_ = h.st.SetPresence(context.Background(), store.Presence{
		DeviceID: deviceID, Online: false, LastSeen: h.now(),
	})
}

func (h *Hub) readLoop(ctx context.Context, lc *liveConn) {
	defer h.wg.Done()
	defer lc.close(websocket.StatusNoStatusRcvd, "read ended")
	for {
		_, raw, err := lc.c.Read(ctx)
		if err != nil {
			return
		}
		lc.lastSeen.Store(h.now().UnixMilli())
		var in inbound
		if err := json.Unmarshal(raw, &in); err != nil {
			continue
		}
		switch in.Type {
		case InHeartbeat, InPong:
			// Liveness only; lastSeen already updated.
		case InSubscribe:
			// Auto-subscribed to the own-user topic at connect.
			// Cross-user topics are ignored, never granted.
			want := "user:" + lc.userID
			if in.Topic != "" && in.Topic != want && in.Topic != lc.deviceID {
				h.logf("ws: device=%s denied subscribe topic=%s", lc.deviceID, in.Topic)
			}
		default:
			// Unknown inbound types ignored per additive-only rule.
		}
	}
}

func (h *Hub) writeLoop(ctx context.Context, lc *liveConn) {
	defer h.wg.Done()
	defer lc.close(websocket.StatusNoStatusRcvd, "write ended")
	hb := time.NewTicker(h.hbInterval)
	defer hb.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case raw := <-lc.send:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := lc.c.Write(wctx, websocket.MessageText, raw)
			cancel()
			if err != nil {
				return
			}
		case <-hb.C:
			env := Envelope{
				ProtocolVersion: ProtocolVersion,
				MsgID:           NewID(),
				Type:            EventHeartbeat,
				To:              lc.deviceID,
				Payload:         map[string]any{"interval_seconds": int(h.hbInterval / time.Second)},
			}
			raw, _ := json.Marshal(env)
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := lc.c.Write(wctx, websocket.MessageText, raw)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (lc *liveConn) close(code websocket.StatusCode, reason string) {
	lc.closeOnce.Do(func() {
		lc.cancel()
		_ = lc.c.Close(code, reason)
	})
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

// protocolToken treats the last offered subprotocol as the token unless
// the client only offered the version tag.
func protocolToken(hdr string) string {
	if hdr == "" {
		return ""
	}
	parts := strings.Split(hdr, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		p := strings.TrimSpace(parts[i])
		if p == "" || p == "calcar-ws-v1" {
			continue
		}
		return p
	}
	return ""
}

func selectSubprotocol(hdr string) []string {
	for _, p := range strings.Split(hdr, ",") {
		if strings.TrimSpace(p) == "calcar-ws-v1" {
			return []string{"calcar-ws-v1"}
		}
	}
	return nil
}
