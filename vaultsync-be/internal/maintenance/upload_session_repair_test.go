package maintenance

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestCompleteRecoveredUploadSessionMarksCompletedWhenVersionAlreadyExists(t *testing.T) {
	db := newUploadSessionRepairTestDB(t)
	if _, err := db.Exec(`
		INSERT INTO upload_sessions (
			id, user_id, device_id, sync_root_id, object_id, version_id,
			total_size, chunk_size, received_size, status, metadata_json, created_at
		)
		VALUES ('session-1', 'u1', 'dev-1', 'root-1', 'obj-1', 'ver-1', 5, 1024, 5, 'pending', '{}', '2026-07-29T00:00:00Z');
		INSERT INTO file_versions (
			id, user_id, sync_root_id, object_id, encrypted_name,
			content_path, content_hash, size_bytes, metadata_json, created_at
		)
		VALUES ('ver-1', 'u1', 'root-1', 'obj-1', 'plain:a.txt', '/data/objects/u1/plain/dev-1/root-1/a.txt', 'hash', 5, '{}', '2026-07-29T00:00:00Z');
	`); err != nil {
		t.Fatalf("seed data: %v", err)
	}

	err := completeRecoveredUploadSession(context.Background(), db, repairUploadSessionRow{
		ID:        "session-1",
		UserID:    "u1",
		VersionID: "ver-1",
	}, "plain:a.txt", "/data/objects/u1/plain/dev-1/root-1/a.txt", "hash", 5)
	if err != nil {
		t.Fatalf("complete recovered upload: %v", err)
	}

	var status string
	var receivedSize int64
	if err := db.QueryRow(`SELECT status, received_size FROM upload_sessions WHERE id='session-1'`).Scan(&status, &receivedSize); err != nil {
		t.Fatalf("read upload session: %v", err)
	}
	if status != "completed" || receivedSize != 5 {
		t.Fatalf("unexpected upload session state: status=%s received=%d", status, receivedSize)
	}
}

func newUploadSessionRepairTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "vaultsync.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	schema := `
CREATE TABLE upload_sessions (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	device_id TEXT NOT NULL,
	sync_root_id TEXT NOT NULL,
	object_id TEXT NOT NULL,
	version_id TEXT NOT NULL,
	total_size INTEGER NOT NULL,
	chunk_size INTEGER NOT NULL,
	received_size INTEGER NOT NULL,
	status TEXT NOT NULL,
	metadata_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE file_versions (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	sync_root_id TEXT NOT NULL,
	object_id TEXT NOT NULL,
	encrypted_name TEXT NOT NULL,
	content_path TEXT NOT NULL,
	content_hash TEXT NOT NULL,
	size_bytes INTEGER NOT NULL,
	metadata_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE sync_events (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	change_type TEXT NOT NULL,
	version_id TEXT NOT NULL DEFAULT '',
	tombstone_id TEXT NOT NULL DEFAULT '',
	sync_root_id TEXT NOT NULL,
	object_id TEXT NOT NULL,
	created_at TEXT NOT NULL
);
`
	if _, err := db.Exec(schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	return db
}
