package store

import (
	"path/filepath"
	"testing"
)

func TestOpenRunsMigrationsAndEnablesWAL(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vaultsync.db")

	db, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() {
		_ = db.Close()
	})

	var journalMode string
	if err := db.QueryRow("PRAGMA journal_mode;").Scan(&journalMode); err != nil {
		t.Fatalf("query journal_mode: %v", err)
	}
	if journalMode != "wal" {
		t.Fatalf("expected journal_mode wal, got %q", journalMode)
	}

	var exists int
	if err := db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'users';`).Scan(&exists); err != nil {
		t.Fatalf("check users table: %v", err)
	}
	if exists != 1 {
		t.Fatal("expected users table to exist")
	}
}
