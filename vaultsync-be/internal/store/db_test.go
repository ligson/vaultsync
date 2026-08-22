package store

import (
	"database/sql"
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
		"users":             {"id", "email", "password_hash", "role", "status", "quota_bytes", "used_bytes", "created_at", "username", "nickname"},
		"user_avatars":      {"user_id", "content_path", "content_hash", "size_bytes", "updated_at"},
		"sessions":          {"token_id", "user_id", "device_id", "created_at", "expires_at", "refresh_token_hash", "refresh_expires_at", "revoked_at"},
		"devices":           {"id", "user_id", "name", "platform", "client_key", "created_at"},
		"sync_roots":        {"id", "user_id", "device_id", "encrypted_path", "encryption_enabled", "cleanup_policy", "archive_path", "created_at"},
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

func TestMigrateAddsRefreshSessionColumnsWithoutChangingExistingSessions(t *testing.T) {
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "legacy-sessions.db"))
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`
		CREATE TABLE users (
			id TEXT PRIMARY KEY,
			email TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			role TEXT NOT NULL,
			status TEXT NOT NULL,
			quota_bytes INTEGER NOT NULL,
			used_bytes INTEGER NOT NULL,
			created_at TEXT NOT NULL
		);
		CREATE TABLE sessions (
			token_id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			device_id TEXT,
			created_at TEXT NOT NULL,
			expires_at TEXT NOT NULL
		);
		INSERT INTO users VALUES ('user-1', 'alice@example.com', 'hash', 'user', 'active', 1024, 0, '2026-08-01T00:00:00Z');
		INSERT INTO sessions VALUES ('token-1', 'user-1', 'device-1', '2026-08-01T00:00:00Z', '2026-08-02T00:00:00Z');
	`); err != nil {
		t.Fatalf("seed legacy session: %v", err)
	}

	if err := migrate(db); err != nil {
		t.Fatalf("migrate legacy database: %v", err)
	}

	var tokenID, userID, deviceID, refreshHash, refreshExpiresAt, revokedAt string
	if err := db.QueryRow(`
		SELECT token_id, user_id, device_id, refresh_token_hash, refresh_expires_at, revoked_at
		FROM sessions WHERE token_id = 'token-1'
	`).Scan(&tokenID, &userID, &deviceID, &refreshHash, &refreshExpiresAt, &revokedAt); err != nil {
		t.Fatalf("read migrated session: %v", err)
	}
	if tokenID != "token-1" || userID != "user-1" || deviceID != "device-1" ||
		refreshHash != "" || refreshExpiresAt != "" || revokedAt != "" {
		t.Fatalf("legacy session changed unexpectedly: token=%q user=%q device=%q hash=%q expires=%q revoked=%q", tokenID, userID, deviceID, refreshHash, refreshExpiresAt, revokedAt)
	}

	var indexName string
	if err := db.QueryRow(`
		SELECT name FROM sqlite_master
		WHERE type = 'index' AND name = 'idx_sessions_refresh_token_hash'
	`).Scan(&indexName); err != nil {
		t.Fatalf("read refresh token index: %v", err)
	}
}

func TestMigrateAddsDeviceClientKeyToLegacyDatabase(t *testing.T) {
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "legacy.db"))
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	t.Cleanup(func() {
		_ = db.Close()
	})
	if _, err := db.Exec(`
		CREATE TABLE devices (
			id TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			name TEXT NOT NULL,
			platform TEXT NOT NULL,
			created_at TEXT NOT NULL
		);
		INSERT INTO devices (id, user_id, name, platform, created_at)
		VALUES ('dev-1', 'user-1', 'HUAWEI NOH-AN00', 'android', '2026-07-30T00:00:00Z');
	`); err != nil {
		t.Fatalf("seed legacy devices table: %v", err)
	}

	if err := migrate(db); err != nil {
		t.Fatalf("migrate legacy database: %v", err)
	}

	var clientKey string
	if err := db.QueryRow(`SELECT client_key FROM devices WHERE id='dev-1'`).Scan(&clientKey); err != nil {
		t.Fatalf("read client_key: %v", err)
	}
	if clientKey != "" {
		t.Fatalf("legacy client_key = %q, want empty string", clientKey)
	}

	var indexName string
	if err := db.QueryRow(`
		SELECT name
		FROM sqlite_master
		WHERE type = 'index' AND name = 'idx_devices_user_client_key'
	`).Scan(&indexName); err != nil {
		t.Fatalf("read device client key index: %v", err)
	}
}

func TestMigrateAddsProfileColumnsWithoutChangingExistingUsers(t *testing.T) {
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "legacy-users.db"))
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`
		CREATE TABLE users (
			id TEXT PRIMARY KEY,
			email TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			role TEXT NOT NULL,
			status TEXT NOT NULL,
			quota_bytes INTEGER NOT NULL,
			used_bytes INTEGER NOT NULL,
			created_at TEXT NOT NULL
		);
		INSERT INTO users VALUES ('user-1', 'alice@example.com', 'hash', 'user', 'active', 1024, 128, '2026-07-31T00:00:00Z');
	`); err != nil {
		t.Fatalf("seed legacy user: %v", err)
	}

	if err := migrate(db); err != nil {
		t.Fatalf("migrate legacy database: %v", err)
	}

	var email, username, nickname string
	var quota, used int64
	if err := db.QueryRow(`SELECT email, username, nickname, quota_bytes, used_bytes FROM users WHERE id='user-1'`).Scan(&email, &username, &nickname, &quota, &used); err != nil {
		t.Fatalf("read migrated user: %v", err)
	}
	if email != "alice@example.com" || username != "" || nickname != "" || quota != 1024 || used != 128 {
		t.Fatalf("legacy user changed unexpectedly: email=%q username=%q nickname=%q quota=%d used=%d", email, username, nickname, quota, used)
	}
}
