package postgres

import (
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/calcar/calcar/backend/store"
)

func TestMigrationsOrderedAndMarked(t *testing.T) {
	names, err := migrationFilenames()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	want := []string{"0001_init.sql", "0002_pairing.sql", "0003_trust.sql", "0004_aux.sql"}
	if len(names) != len(want) {
		t.Fatalf("got %d migrations %v, want %v", len(names), names, want)
	}
	for i, w := range want {
		if names[i] != w {
			t.Fatalf("migration %d = %q, want %q (full order %v)", i, names[i], w, names)
		}
	}
}

func TestMigrationsUpDownBlocks(t *testing.T) {
	ms, err := loadMigrations()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	for _, m := range ms {
		if strings.Contains(m.upSQL, downMarker) {
			t.Errorf("%s: Up block leaks into Down", m.version)
		}
		if !strings.Contains(m.upSQL, "CREATE TABLE") {
			t.Errorf("%s: Up block has no CREATE TABLE", m.version)
		}
		if !strings.Contains(strings.ToUpper(m.downSQL), "DROP TABLE") {
			t.Errorf("%s: Down block has no DROP TABLE", m.version)
		}
	}
}

func TestMigrationsCoverSchema(t *testing.T) {
	ms, err := loadMigrations()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	var up strings.Builder
	for _, m := range ms {
		up.WriteString(m.upSQL)
		up.WriteString("\n")
	}
	joined := up.String()
	for _, table := range []string{
		"users", "devices", "pairing_sessions", "trust_grants",
		"revocations", "connection_metadata", "push_tokens", "recovery_config",
	} {
		if !strings.Contains(joined, "CREATE TABLE IF NOT EXISTS "+table) {
			t.Errorf("no CREATE TABLE for %s", table)
		}
	}
	for _, want := range []string{
		"owner_phone", "trusted_phone", "computer", // role check
		"UNIQUE (user_id, pubkey)",                               // device binding
		"pending', 'approved', 'rejected', 'expired', 'consumed", // session states
		"join_request_id   TEXT UNIQUE",                          // single join latch
		"decided_at", "granter_device_id", "granter_signature",   // decided fields
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("schema missing %q", want)
		}
	}
}

func TestParseMigrationRejectsBadMarkers(t *testing.T) {
	for _, body := range []string{
		"CREATE TABLE x (id TEXT);",
		"-- +migrate Down\nDROP TABLE x;",
		"-- +migrate Down\nDROP TABLE x;\n-- +migrate Up\nCREATE TABLE x (id TEXT);",
		"-- +migrate Up\n-- +migrate Down\n",
	} {
		if _, err := parseMigration("0009_bad.sql", body); err == nil {
			t.Errorf("expected error for body %q", body)
		}
	}
}

func TestMapPgError(t *testing.T) {
	if got := mapPgError(nil); got != nil {
		t.Errorf("nil maps to %v", got)
	}
	if got := mapPgError(pgx.ErrNoRows); !errors.Is(got, store.ErrNotFound) {
		t.Errorf("ErrNoRows maps to %v, want ErrNotFound", got)
	}
	for code, want := range map[string]error{
		"23505": store.ErrConflict,
		"23514": store.ErrConflict,
		"23503": store.ErrConflict,
	} {
		got := mapPgError(&pgconn.PgError{Code: code})
		if !errors.Is(got, want) {
			t.Errorf("code %s maps to %v, want %v", code, got, want)
		}
	}
	other := errors.New("boom")
	if got := mapPgError(other); got != other {
		t.Errorf("unknown error maps to %v, want passthrough", got)
	}
}

func TestGrantBindingDeterministic(t *testing.T) {
	a := grantBinding("sess", "owner", []byte{1, 2, 3})
	b := grantBinding("sess", "owner", []byte{1, 2, 3})
	c := grantBinding("sess", "owner", []byte{1, 2, 4})
	if string(a) != string(b) {
		t.Error("same inputs give different bindings")
	}
	if string(a) == string(c) {
		t.Error("different pubkeys give the same binding")
	}
	if len(a) != 32 {
		t.Errorf("binding length %d, want 32", len(a))
	}
}
