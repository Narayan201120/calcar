// Package postgres backs the durable half of the store seam with PostgreSQL
// via pgx v5. It owns users, devices, pairing audit rows, append-only trust
// grants and revocations, plus connection, push token, and recovery tables.
// Ephemeral coordination (challenges, tokens, replay, attention) needs Redis
// and reports an explicit error here; see backend/store/combined.go.
package postgres

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/calcar/calcar/backend/store/migrations"
)

const (
	upMarker   = "-- +migrate Up"
	downMarker = "-- +migrate Down"
)

type migration struct {
	version string
	upSQL   string
	downSQL string
}

// loadMigrations parses the embedded files in filename order. Every file must
// carry both the Up and Down markers; anything else fails the build-time
// contract loudly instead of half-applying schema.
func loadMigrations() ([]migration, error) {
	entries, err := migrations.FS.ReadDir(".")
	if err != nil {
		return nil, fmt.Errorf("postgres: read embedded migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	out := make([]migration, 0, len(names))
	for _, n := range names {
		raw, err := migrations.FS.ReadFile(n)
		if err != nil {
			return nil, fmt.Errorf("postgres: read migration %s: %w", n, err)
		}
		m, err := parseMigration(n, string(raw))
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

// migrationFilenames reports the embedded migration files in apply order.
func migrationFilenames() ([]string, error) {
	ms, err := loadMigrations()
	if err != nil {
		return nil, err
	}
	names := make([]string, len(ms))
	for i, m := range ms {
		names[i] = m.version
	}
	return names, nil
}

func parseMigration(name, body string) (migration, error) {
	upIdx := strings.Index(body, upMarker)
	downIdx := strings.Index(body, downMarker)
	if upIdx < 0 || downIdx < 0 || downIdx < upIdx {
		return migration{}, fmt.Errorf(
			"postgres: migration %s must contain %q before %q", name, upMarker, downMarker)
	}
	up := strings.TrimSpace(body[upIdx+len(upMarker) : downIdx])
	down := strings.TrimSpace(body[downIdx+len(downMarker):])
	if up == "" || down == "" {
		return migration{}, fmt.Errorf("postgres: migration %s has empty Up or Down block", name)
	}
	return migration{version: name, upSQL: up, downSQL: down}, nil
}

// Migrate applies pending Up blocks in filename order, tracked in the
// schema_migrations table. It is idempotent: applied versions are skipped.
// Deployments run this before API start and block on failure.
func Migrate(ctx context.Context, connString string) error {
	conn, err := pgx.Connect(ctx, connString)
	if err != nil {
		return fmt.Errorf("postgres: migrate connect: %w", err)
	}
	defer conn.Close(ctx)

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		return fmt.Errorf("postgres: migrate bootstrap: %w", err)
	}

	ms, err := loadMigrations()
	if err != nil {
		return err
	}
	for _, m := range ms {
		var exists bool
		if err := conn.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, m.version,
		).Scan(&exists); err != nil {
			return fmt.Errorf("postgres: migrate check %s: %w", m.version, err)
		}
		if exists {
			continue
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return fmt.Errorf("postgres: migrate begin %s: %w", m.version, err)
		}
		if _, err := tx.Exec(ctx, m.upSQL); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("postgres: migrate apply %s: %w", m.version, err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO schema_migrations (version) VALUES ($1)`, m.version,
		); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("postgres: migrate record %s: %w", m.version, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("postgres: migrate commit %s: %w", m.version, err)
		}
	}
	return nil
}
