package service

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/ligson/vaultsync/internal/store"
)

func TestRegisterReconcilesEmptyAndroidDuplicateWithCanonicalDevice(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "vaultsync.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	_, err = db.Exec(`
		INSERT INTO users (id, email, password_hash, created_at)
		VALUES ('user-1', 'alice@example.com', 'hash', '2026-07-01T00:00:00Z');
		INSERT INTO devices (id, user_id, name, platform, client_key, created_at)
		VALUES
			('canonical', 'user-1', 'Solana Mobile Inc. Seeker', 'android', 'vaultsync-device:v1:android:old', '2026-07-07T00:00:00Z'),
			('duplicate', 'user-1', 'Solana Mobile Inc. Seeker', 'android', 'vaultsync-device:v1:android:new', '2026-09-10T00:00:00Z');
		INSERT INTO sync_roots (id, user_id, device_id, encrypted_path, cleanup_policy, created_at)
		VALUES ('root-1', 'user-1', 'canonical', 'path', 'keep', '2026-07-07T00:00:00Z');
	`)
	if err != nil {
		t.Fatalf("seed device records: %v", err)
	}

	service := NewDeviceService(store.NewDeviceRepo(db))
	device, err := service.Register(
		context.Background(),
		"user-1",
		"Solana Mobile Inc. Seeker",
		"android",
		"vaultsync-device:v2:android:stable",
		"duplicate",
	)
	if err != nil {
		t.Fatalf("register device: %v", err)
	}
	if device.ID != "canonical" {
		t.Fatalf("device id = %q, want canonical", device.ID)
	}

	var deviceCount, canonicalRootCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM devices WHERE user_id = 'user-1'`).Scan(&deviceCount); err != nil {
		t.Fatalf("count devices: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM sync_roots WHERE device_id = 'canonical'`).Scan(&canonicalRootCount); err != nil {
		t.Fatalf("count canonical roots: %v", err)
	}
	if deviceCount != 2 || canonicalRootCount != 1 {
		t.Fatalf("unexpected data changes: devices=%d roots=%d", deviceCount, canonicalRootCount)
	}
}

func TestRegisterKeepsCurrentDeviceWhenCanonicalMatchIsAmbiguous(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "vaultsync.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	_, err = db.Exec(`
		INSERT INTO users (id, email, password_hash, created_at)
		VALUES ('user-1', 'alice@example.com', 'hash', '2026-07-01T00:00:00Z');
		INSERT INTO devices (id, user_id, name, platform, client_key, created_at)
		VALUES
			('phone-a', 'user-1', 'Example Phone', 'android', 'vaultsync-device:v1:android:a', '2026-07-07T00:00:00Z'),
			('phone-b', 'user-1', 'Example Phone', 'android', 'vaultsync-device:v1:android:b', '2026-07-08T00:00:00Z'),
			('current', 'user-1', 'Example Phone', 'android', 'vaultsync-device:v1:android:current', '2026-09-10T00:00:00Z');
		INSERT INTO sync_roots (id, user_id, device_id, encrypted_path, cleanup_policy, created_at)
		VALUES
			('root-a', 'user-1', 'phone-a', 'path-a', 'keep', '2026-07-07T00:00:00Z'),
			('root-b', 'user-1', 'phone-b', 'path-b', 'keep', '2026-07-08T00:00:00Z');
	`)
	if err != nil {
		t.Fatalf("seed ambiguous device records: %v", err)
	}

	service := NewDeviceService(store.NewDeviceRepo(db))
	device, err := service.Register(
		context.Background(),
		"user-1",
		"Example Phone",
		"android",
		"vaultsync-device:v2:android:stable",
		"current",
	)
	if err != nil {
		t.Fatalf("register device: %v", err)
	}
	if device.ID != "current" {
		t.Fatalf("device id = %q, want current", device.ID)
	}
}
