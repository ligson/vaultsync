package storage

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestStoreAvatarReplacesAtomicallyAndEnforcesSize(t *testing.T) {
	dataDir := t.TempDir()
	storage := NewFSStorage(dataDir)

	path, hashValue, size, err := storage.StoreAvatar(
		"user-1",
		bytes.NewReader([]byte("encrypted-avatar")),
		1024,
	)
	if err != nil {
		t.Fatalf("store avatar: %v", err)
	}
	if path != "avatars/user-1/avatar.bin" || size != 16 || hashValue == "" {
		t.Fatalf("unexpected avatar metadata: path=%q size=%d hash=%q", path, size, hashValue)
	}
	content, err := os.ReadFile(filepath.Join(dataDir, "avatars/user-1/avatar.bin"))
	if err != nil {
		t.Fatalf("read avatar: %v", err)
	}
	if string(content) != "encrypted-avatar" {
		t.Fatalf("avatar content = %q", string(content))
	}

	_, _, _, err = storage.StoreAvatar("user-1", bytes.NewReader(make([]byte, 1025)), 1024)
	if err != ErrMaxSizeExceeded {
		t.Fatalf("expected max size error, got %v", err)
	}
}

func TestFinalizeUploadReusesExistingFinalizedFile(t *testing.T) {
	dataDir := t.TempDir()
	storage := NewFSStorage(dataDir)
	placement := UploadObjectPlacement{
		UserID:       "user-1",
		DeviceID:     "device-1",
		SyncRootID:   "root-1",
		SessionID:    "session-1",
		ObjectID:     "obj-1",
		VersionID:    "ver-1",
		RelativePath: "WeiXin/2026/a.jpg",
		ExpectedSize: 5,
	}
	versionPath := filepath.Join(
		dataDir,
		"objects",
		"user-1",
		"plain",
		"device-1",
		"root-1",
		".vaultsync_versions",
		"obj-1",
		"ver-1",
		"a.jpg",
	)
	if err := os.MkdirAll(filepath.Dir(versionPath), 0o755); err != nil {
		t.Fatalf("mkdir version path: %v", err)
	}
	if err := os.WriteFile(versionPath, []byte("hello"), 0o644); err != nil {
		t.Fatalf("write finalized file: %v", err)
	}

	contentPath, hashValue, size, err := storage.FinalizeUpload(placement)
	if err != nil {
		t.Fatalf("finalize existing file: %v", err)
	}

	if contentPath != versionPath {
		t.Fatalf("content path mismatch: got %q want %q", contentPath, versionPath)
	}
	if size != 5 {
		t.Fatalf("size mismatch: got %d", size)
	}
	if hashValue != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" {
		t.Fatalf("hash mismatch: %s", hashValue)
	}
	mirrorPath := filepath.Join(
		dataDir,
		"objects",
		"user-1",
		"plain",
		"device-1",
		"root-1",
		"WeiXin",
		"2026",
		"a.jpg",
	)
	mirrorBytes, err := os.ReadFile(mirrorPath)
	if err != nil {
		t.Fatalf("read mirror: %v", err)
	}
	if string(mirrorBytes) != "hello" {
		t.Fatalf("mirror content mismatch: %q", string(mirrorBytes))
	}
}

func TestInspectRecoverableUploadDoesNotMovePartFile(t *testing.T) {
	dataDir := t.TempDir()
	storage := NewFSStorage(dataDir)
	partPath := filepath.Join(dataDir, "uploads", "user-1", "session-1.part")
	if err := os.MkdirAll(filepath.Dir(partPath), 0o755); err != nil {
		t.Fatalf("mkdir part path: %v", err)
	}
	if err := os.WriteFile(partPath, []byte("hello"), 0o644); err != nil {
		t.Fatalf("write part file: %v", err)
	}

	contentPath, _, size, err := storage.InspectRecoverableUpload(UploadObjectPlacement{
		UserID:       "user-1",
		DeviceID:     "device-1",
		SyncRootID:   "root-1",
		SessionID:    "session-1",
		ObjectID:     "obj-1",
		VersionID:    "ver-1",
		RelativePath: "WeiXin/2026/a.jpg",
		ExpectedSize: 5,
	})
	if err != nil {
		t.Fatalf("inspect recoverable upload: %v", err)
	}
	if size != 5 {
		t.Fatalf("size mismatch: got %d", size)
	}
	if _, err := os.Stat(partPath); err != nil {
		t.Fatalf("part file should remain in dry-run inspection: %v", err)
	}
	if _, err := os.Stat(contentPath); !os.IsNotExist(err) {
		t.Fatalf("content path should not be created during inspection: %v", err)
	}
}
