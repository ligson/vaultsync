package maintenance

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestStorageLayoutMigrationMovesPlainVersionAndPublishesMirror(t *testing.T) {
	dataDir := t.TempDir()
	db := newStorageMigrationTestDB(t)
	writeObject(t, dataDir, "/data/objects/u1/plain/ver-1.bin", "hello")
	insertSyncRoot(t, db, "root-1", "u1", "dev-1", 0)
	insertVersion(t, db, "ver-1", "u1", "root-1", "obj-1", "/data/objects/u1/plain/ver-1.bin", "hello", `{"relative_path":"docs/a.txt","encrypted_name":"plain:a.txt"}`)

	summary, err := RunStorageLayoutMigration(context.Background(), db, StorageLayoutOptions{
		DataDir:       dataDir,
		StoredDataDir: "/data",
		Mode:          StorageLayoutApply,
		Now:           fixedStorageMigrationTime,
	})
	if err != nil {
		t.Fatalf("run migration: %v", err)
	}
	if summary.Errors != 0 || summary.Migrated != 1 || summary.Mirrored != 1 {
		t.Fatalf("unexpected summary: %+v", summary)
	}

	wantStored := "/data/objects/u1/plain/dev-1/root-1/.vaultsync_versions/obj-1/ver-1/a.txt"
	var gotStored string
	if err := db.QueryRow(`SELECT content_path FROM file_versions WHERE id='ver-1'`).Scan(&gotStored); err != nil {
		t.Fatalf("read content_path: %v", err)
	}
	if gotStored != wantStored {
		t.Fatalf("content_path = %q, want %q", gotStored, wantStored)
	}
	assertFileContent(t, filepath.Join(dataDir, "objects/u1/plain/dev-1/root-1/.vaultsync_versions/obj-1/ver-1/a.txt"), "hello")
	assertFileContent(t, filepath.Join(dataDir, "objects/u1/plain/dev-1/root-1/docs/a.txt"), "hello")
}

func TestStorageLayoutCleanupDeletesOnlyUnreferencedOldFile(t *testing.T) {
	dataDir := t.TempDir()
	db := newStorageMigrationTestDB(t)
	oldPath := filepath.Join(dataDir, "objects/u1/plain/ver-1.bin")
	newPath := filepath.Join(dataDir, "objects/u1/plain/dev-1/root-1/.vaultsync_versions/obj-1/ver-1/a.txt")
	writeFile(t, oldPath, "hello")
	writeFile(t, newPath, "hello")
	reportPath := filepath.Join(dataDir, "report.jsonl")
	report := `{"version_id":"ver-1","old_stored_path":"/data/objects/u1/plain/ver-1.bin","new_stored_path":"/data/objects/u1/plain/dev-1/root-1/.vaultsync_versions/obj-1/ver-1/a.txt","old_physical_path":"` + oldPath + `","new_physical_path":"` + newPath + `","content_hash":"` + sha256Text("hello") + `","size_bytes":5}` + "\n"
	if err := os.WriteFile(reportPath, []byte(report), 0o644); err != nil {
		t.Fatalf("write report: %v", err)
	}
	insertSyncRoot(t, db, "root-1", "u1", "dev-1", 0)
	insertVersion(t, db, "ver-1", "u1", "root-1", "obj-1", "/data/objects/u1/plain/dev-1/root-1/.vaultsync_versions/obj-1/ver-1/a.txt", "hello", `{"relative_path":"docs/a.txt"}`)

	summary, err := RunStorageLayoutMigration(context.Background(), db, StorageLayoutOptions{
		DataDir:       dataDir,
		StoredDataDir: "/data",
		ReportPath:    reportPath,
		Mode:          StorageLayoutCleanup,
	})
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if summary.Errors != 0 || summary.Deleted != 1 {
		t.Fatalf("unexpected summary: %+v", summary)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("old file still exists or stat failed: %v", err)
	}
}

func TestStorageLayoutMigrationMovesOrphanEncryptedVersionToLegacyDeviceBucket(t *testing.T) {
	dataDir := t.TempDir()
	db := newStorageMigrationTestDB(t)
	writeObject(t, dataDir, "/data/objects/u1/ver-enc.bin", "cipher")
	insertVersion(t, db, "ver-enc", "u1", "missing-root", "obj-enc", "/data/objects/u1/ver-enc.bin", "cipher", `{"format":"vaultsync-encrypted-metadata-v1","encrypted_name":"vaultsync-name:v1:abc"}`)

	summary, err := RunStorageLayoutMigration(context.Background(), db, StorageLayoutOptions{
		DataDir:       dataDir,
		StoredDataDir: "/data",
		Mode:          StorageLayoutApply,
		Now:           fixedStorageMigrationTime,
	})
	if err != nil {
		t.Fatalf("run migration: %v", err)
	}
	if summary.Errors != 0 || summary.Migrated != 1 || summary.Mirrored != 0 {
		t.Fatalf("unexpected summary: %+v", summary)
	}

	wantStored := "/data/objects/u1/encrypted/__legacy_device__/missing-root/ver-enc.bin"
	var gotStored string
	if err := db.QueryRow(`SELECT content_path FROM file_versions WHERE id='ver-enc'`).Scan(&gotStored); err != nil {
		t.Fatalf("read content_path: %v", err)
	}
	if gotStored != wantStored {
		t.Fatalf("content_path = %q, want %q", gotStored, wantStored)
	}
	assertFileContent(t, filepath.Join(dataDir, "objects/u1/encrypted/__legacy_device__/missing-root/ver-enc.bin"), "cipher")
}

func newStorageMigrationTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "vaultsync.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	schema := `
CREATE TABLE sync_roots (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, device_id TEXT NOT NULL, encryption_enabled INTEGER NOT NULL DEFAULT 1);
CREATE TABLE file_versions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, sync_root_id TEXT NOT NULL, object_id TEXT NOT NULL, content_path TEXT NOT NULL, content_hash TEXT NOT NULL, size_bytes INTEGER NOT NULL, metadata_json TEXT NOT NULL);
CREATE TABLE file_tombstones (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, device_id TEXT NOT NULL, sync_root_id TEXT NOT NULL, object_id TEXT NOT NULL, metadata_json TEXT NOT NULL, created_at TEXT NOT NULL);
`
	if _, err := db.Exec(schema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	return db
}

func insertSyncRoot(t *testing.T, db *sql.DB, id, userID, deviceID string, encrypted int) {
	t.Helper()
	if _, err := db.Exec(`INSERT INTO sync_roots (id, user_id, device_id, encryption_enabled) VALUES (?, ?, ?, ?)`, id, userID, deviceID, encrypted); err != nil {
		t.Fatalf("insert sync root: %v", err)
	}
}

func insertVersion(t *testing.T, db *sql.DB, id, userID, syncRootID, objectID, contentPath, content, metadataJSON string) {
	t.Helper()
	if _, err := db.Exec(`INSERT INTO file_versions (id, user_id, sync_root_id, object_id, content_path, content_hash, size_bytes, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, id, userID, syncRootID, objectID, contentPath, sha256Text(content), len(content), metadataJSON); err != nil {
		t.Fatalf("insert version: %v", err)
	}
}

func writeObject(t *testing.T, dataDir, storedPath, content string) {
	t.Helper()
	rel, err := filepath.Rel("/data", storedPath)
	if err != nil {
		t.Fatalf("rel: %v", err)
	}
	writeFile(t, filepath.Join(dataDir, rel), content)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
}

func assertFileContent(t *testing.T, path, want string) {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(content) != want {
		t.Fatalf("content of %s = %q, want %q", path, string(content), want)
	}
}

func sha256Text(content string) string {
	hash := sha256.Sum256([]byte(content))
	return hex.EncodeToString(hash[:])
}

func fixedStorageMigrationTime() time.Time {
	return time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
}
