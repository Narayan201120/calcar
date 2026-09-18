//go:build integration

// Integration tests for the Redis half against live Redis. Reads REDIS_ADDR
// (default localhost:6379). Tests fail closed (no skip) when Redis is down.
package redis_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/calcar/calcar/backend/store"
	rdstore "github.com/calcar/calcar/backend/store/redis"
)

func redisAddr() string {
	return "localhost:6379"
}

func mustRedis(t *testing.T) *rdstore.Store {
	t.Helper()
	ctx := context.Background()
	s, err := rdstore.NewStore(ctx, redisAddr())
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func testID(t *testing.T, prefix string) string {
	t.Helper()
	return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
}

func TestIntegrationReplayDedupe(t *testing.T) {
	ctx := context.Background()
	s := mustRedis(t)
	req := testID(t, "req")
	if err := s.CheckAndMarkRequest(ctx, req, time.Minute); err != nil {
		t.Fatalf("first mark: %v", err)
	}
	if err := s.CheckAndMarkRequest(ctx, req, time.Minute); !errors.Is(err, store.ErrReplayed) {
		t.Fatalf("second mark err = %v, want ErrReplayed", err)
	}
	if err := s.CheckAndMarkRequest(ctx, "", time.Minute); !errors.Is(err, store.ErrConflict) {
		t.Errorf("empty id err = %v, want ErrConflict", err)
	}
}

func TestIntegrationTokenLifecycle(t *testing.T) {
	ctx := context.Background()
	s := mustRedis(t)
	device := testID(t, "dev")

	tok, err := s.IssueAccessToken(ctx, device, "user-1", 15*time.Minute)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if tok == "" {
		t.Fatal("empty token")
	}
	gotDev, gotUser, err := s.ResolveAccessToken(ctx, tok)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if gotDev != device || gotUser != "user-1" {
		t.Errorf("resolved (%q,%q), want (%q,user-1)", gotDev, gotUser, device)
	}
	if err := s.RevokeDeviceTokens(ctx, device); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, _, err := s.ResolveAccessToken(ctx, tok); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("resolve after revoke err = %v, want ErrNotFound", err)
	}
	// Revoking twice is nil: gone stays gone.
	if err := s.RevokeDeviceTokens(ctx, device); err != nil {
		t.Errorf("second revoke: %v", err)
	}
	if _, _, err := s.ResolveAccessToken(ctx, "no-such-token"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown token err = %v, want ErrNotFound", err)
	}
}

func TestIntegrationChallengeSingleUse(t *testing.T) {
	ctx := context.Background()
	s := mustRedis(t)
	device := testID(t, "dev")

	ch, err := s.IssueChallenge(ctx, device)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if err := s.ConsumeChallenge(ctx, device, "wrong"); !errors.Is(err, store.ErrConflict) {
		t.Errorf("wrong challenge err = %v, want ErrConflict", err)
	}
	if err := s.ConsumeChallenge(ctx, device, ch); err != nil {
		t.Fatalf("consume: %v", err)
	}
	if err := s.ConsumeChallenge(ctx, device, ch); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("second consume err = %v, want ErrNotFound", err)
	}
}

func TestIntegrationPresenceAndPush(t *testing.T) {
	ctx := context.Background()
	s := mustRedis(t)
	device := testID(t, "dev")

	if err := s.SetPresence(ctx, store.Presence{DeviceID: device, Online: true, ConnID: "conn-1"}); err != nil {
		t.Fatalf("set presence: %v", err)
	}
	p, err := s.GetPresence(ctx, device)
	if err != nil {
		t.Fatalf("get presence: %v", err)
	}
	if !p.Online || p.ConnID != "conn-1" {
		t.Errorf("presence = %+v, want online conn-1", p)
	}
	if dev, err := s.LookupConn(ctx, "conn-1"); err != nil || dev != device {
		t.Errorf("conn lookup = %q, %v", dev, err)
	}
	if err := s.SetPushToken(ctx, device, "fcm", "token-abc"); err != nil {
		t.Fatalf("set push token: %v", err)
	}
	if _, err := s.GetPresence(ctx, "never-seen"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown presence err = %v, want ErrNotFound", err)
	}
}
