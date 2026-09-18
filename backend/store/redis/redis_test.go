package redis

import (
	"strings"
	"testing"

	"github.com/calcar/calcar/backend/store"
)

func TestKeyNamespaces(t *testing.T) {
	cases := map[string]string{
		pairingKey("s1"):    "pairing:s1",
		presenceKey("d1"):   "presence:d1",
		connKey("c1"):       "conn:c1",
		tokenKey("t1"):      "tokens:t1",
		tokenIndexKey("d1"): "tokens_by_device:d1",
		challengeKey("d1"):  "challenges:d1",
		replayKey("r1"):     "replay:r1",
		notifyKey("u1"):     "notify:u1",
		pushTokensKey("d1"): "pushtokens:d1",
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("key = %q, want %q", got, want)
		}
	}
	seen := map[string]bool{}
	for _, k := range []string{
		pairingKey("x"), presenceKey("x"), connKey("x"), tokenKey("x"),
		challengeKey("x"), replayKey("x"), notifyKey("x"), pushTokensKey("x"),
	} {
		prefix := k[:strings.Index(k, ":")+1]
		if seen[prefix] {
			t.Errorf("namespace collision on %q", prefix)
		}
		seen[prefix] = true
	}
}

func TestAttentionRoundTrip(t *testing.T) {
	in := store.Attention{ComputerID: "pc-1", WorkflowID: "wf-9", Kind: "approval"}
	raw := encodeAttention(in)
	if strings.Contains(raw, "secret") {
		t.Error("encoder invents content")
	}
	if got := decodeAttention(raw); got != in {
		t.Errorf("round trip = %+v, want %+v", got, in)
	}
}

func TestTTLConstants(t *testing.T) {
	if presenceTTL.Seconds() != 90 {
		t.Errorf("presence TTL = %v, want 90s", presenceTTL)
	}
	if challengeTTL.Minutes() != 5 {
		t.Errorf("challenge TTL = %v, want 5m", challengeTTL)
	}
	if notifyTrim != 100 {
		t.Errorf("notify trim = %d, want 100", notifyTrim)
	}
}
