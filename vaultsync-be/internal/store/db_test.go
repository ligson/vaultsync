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

	wantColumns := map[string][]string{
		"users":             {"id", "email", "password_hash", "role", "status", "quota_bytes", "used_bytes", "created_at"},
		"sessions":          {"token_id", "user_id", "device_id", "created_at", "expires_at"},
		"devices":           {"id", "user_id", "name", "platform", "created_at"},
		"sync_roots":        {"id", "user_id", "device_id", "encrypted_path", "cleanup_policy", "archive_path", "created_at"},
		"upload_sessions":   {"id", "user_id", "device_id", "sync_root_id", "object_id", "version_id", "total_size", "chunk_size", "received_size", "status", "metadata_json", "created_at"},
		"file_versions":     {"id", "user_id", "sync_root_id", "object_id", "encrypted_name", "content_path", "content_hash", "size_bytes", "metadata_json", "created_at"},
		"file_tombstones":   {"id", "user_id", "device_id", "sync_root_id", "object_id", "metadata_json", "created_at"},
		"sync_events":       {"id", "user_id", "change_type", "version_id", "tombstone_id", "sync_root_id", "object_id", "created_at"},
		"sync_cursors":      {"user_id", "device_id", "cursor_value", "version_id", "created_at"},
		"audit_logs":        {"id", "user_id", "action", "details_json", "created_at"},
		"system_settings":   {"key", "value", "updated_at"},
		"download_releases": {"platform", "file_name", "version", "download_url", "size_bytes", "updated_at"},
	}

	for table, columns := range wantColumns {
		var exists int
		if err := db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;`, table).Scan(&exists); err != nil {
			t.Fatalf("check %s table: %v", table, err)
		}
		if exists != 1 {
			t.Fatalf("expected %s table to exist", table)
		}

		rows, err := db.Query(`PRAGMA table_info(` + table + `);`)
		if err != nil {
			t.Fatalf("describe %s table: %v", table, err)
		}

		got := make([]string, 0, len(columns))
		for rows.Next() {
			var (
				cid     int
				name    string
				ctype   string
				notnull int
				dflt    any
				pk      int
			)
			if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
				rows.Close()
				t.Fatalf("scan %s columns: %v", table, err)
			}
			got = append(got, name)
		}
		if err := rows.Close(); err != nil {
			t.Fatalf("close %s columns: %v", table, err)
		}

		if len(got) != len(columns) {
			t.Fatalf("table %s column count mismatch: got %v want %v", table, got, columns)
		}
		for i, column := range columns {
			if got[i] != column {
				t.Fatalf("table %s column %d mismatch: got %q want %q (full=%v)", table, i, got[i], column, got)
			}
		}
	}
}
