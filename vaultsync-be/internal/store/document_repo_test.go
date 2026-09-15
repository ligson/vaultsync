package store

import (
	"context"
	"testing"

	"github.com/ligson/vaultsync/internal/domain"
)

func TestDocumentRepoIndexesAndFiltersDocumentsAcrossDevices(t *testing.T) {
	db, err := Open(t.TempDir() + "/documents.db")
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	_, err = db.Exec(`
		INSERT INTO users (id, email, password_hash, role, status, quota_bytes, used_bytes, created_at)
		VALUES ('user-1', 'one@example.com', 'hash', 'user', 'active', 100000, 0, '2026-09-15T00:00:00Z');
		INSERT INTO devices (id, user_id, name, platform, created_at)
		VALUES ('device-1', 'user-1', 'MacBook', 'macos', '2026-09-15T00:00:00Z'),
		       ('device-2', 'user-1', 'Seeker', 'android', '2026-09-15T00:00:00Z');
		INSERT INTO sync_roots (id, user_id, device_id, encrypted_path, cleanup_policy, created_at)
		VALUES ('root-1', 'user-1', 'device-1', 'encrypted-root-1', 'keep', '2026-09-15T00:00:00Z'),
		       ('root-2', 'user-1', 'device-2', 'encrypted-root-2', 'keep', '2026-09-15T00:00:00Z');
		INSERT INTO file_versions (id, user_id, sync_root_id, object_id, encrypted_name, content_path, content_hash, size_bytes, metadata_json, created_at)
		VALUES ('version-1', 'user-1', 'root-1', 'object-1', 'encrypted-a', '/data/a', 'hash-a', 100, '{}', '2026-09-14T00:00:00Z'),
		       ('version-2', 'user-1', 'root-2', 'object-2', 'encrypted-b', '/data/b', 'hash-b', 200, '{}', '2026-09-15T00:00:00Z');
	`)
	if err != nil {
		t.Fatalf("seed documents: %v", err)
	}

	repo := NewDocumentRepo(db)
	indexed, marked, err := repo.InsertBackfill(context.Background(), "user-1", []domain.DocumentAsset{
		{ID: "document-1", SyncRootID: "root-1", ObjectID: "object-1", VersionID: "version-1", DocumentType: "pdf", DocumentFormat: "pdf", UpdatedAt: "2026-09-14T00:00:00Z"},
		{ID: "document-2", SyncRootID: "root-2", ObjectID: "object-2", VersionID: "version-2", DocumentType: "office", DocumentFormat: "docx", UpdatedAt: "2026-09-15T00:00:00Z"},
	}, nil, "2026-09-15T00:00:00Z")
	if err != nil || indexed != 2 || marked != 2 {
		t.Fatalf("index documents: indexed=%d marked=%d err=%v", indexed, marked, err)
	}

	devices, err := repo.ListDevices(context.Background(), "user-1")
	if err != nil || len(devices) != 2 || devices[0].ID != "device-1" || devices[1].ID != "device-2" {
		t.Fatalf("list devices: %#v err=%v", devices, err)
	}
	items, err := repo.ListItems(context.Background(), "user-1", "", "device-2", "size", "desc", 0, 10)
	if err != nil || len(items) != 1 || items[0].VersionID != "version-2" || items[0].SizeBytes != 200 {
		t.Fatalf("list filtered documents: %#v err=%v", items, err)
	}

	indexed, marked, err = repo.InsertBackfill(context.Background(), "user-1", []domain.DocumentAsset{
		{ID: "document-2-retry", SyncRootID: "root-2", ObjectID: "object-2", VersionID: "version-2", DocumentType: "office", DocumentFormat: "docx", UpdatedAt: "2026-09-15T00:00:00Z"},
	}, nil, "2026-09-15T00:00:00Z")
	if err != nil || indexed != 0 || marked != 1 {
		t.Fatalf("repeat index should be idempotent: indexed=%d marked=%d err=%v", indexed, marked, err)
	}
}
