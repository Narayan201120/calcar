// Package migrations embeds the Postgres schema files in apply order.
// The postgres package reads FS; files here must each carry both the
// "-- +migrate Up" and "-- +migrate Down" markers.
package migrations

import "embed"

// FS is the embedded schema. Read *.sql entries sorted by name to apply Up
// blocks in order, tracked by the schema_migrations table.
//
//go:embed *.sql
var FS embed.FS
