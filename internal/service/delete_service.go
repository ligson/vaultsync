package service

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/store"
)

type DeleteService struct {
	db           *sql.DB
	deviceRepo   *store.DeviceRepo
	syncRootRepo *store.SyncRootRepo
	now          func() time.Time
}

func NewDeleteService(db *sql.DB, deviceRepo *store.DeviceRepo, syncRootRepo *store.SyncRootRepo) *DeleteService {
	return &DeleteService{
		db:           db,
		deviceRepo:   deviceRepo,
		syncRootRepo: syncRootRepo,
		now:          func() time.Time { return time.Now().UTC() },
	}
}

func (s *DeleteService) DeleteObject(ctx context.Context, userID, deviceID, syncRootID, objectID string) (map[string]string, error) {
	deviceID = strings.TrimSpace(deviceID)
	syncRootID = strings.TrimSpace(syncRootID)
	objectID = strings.TrimSpace(objectID)
	if deviceID == "" {
		return nil, errors.New("device id is required")
	}
	if syncRootID == "" {
		return nil, errors.New("sync root id is required")
	}
	if objectID == "" {
		return nil, errors.New("object id is required")
	}
	deviceExists, err := s.deviceRepo.ExistsForUser(ctx, userID, deviceID)
	if err != nil {
		return nil, err
	}
	if !deviceExists {
		return nil, errors.New("device does not belong to user")
	}
	root, err := s.syncRootRepo.GetForUser(ctx, userID, syncRootID)
	if err != nil {
		return nil, errors.New("sync root does not belong to user")
	}
	if root.DeviceID != deviceID {
		return nil, errors.New("sync root does not belong to device")
	}

	tombstoneID := newID()
	createdAt := s.now().Format(time.RFC3339)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx, `
		INSERT INTO file_tombstones (id, user_id, device_id, sync_root_id, object_id, metadata_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, tombstoneID, userID, deviceID, syncRootID, objectID, `{}`, createdAt)
	if err != nil {
		return nil, err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO sync_events (
			id, user_id, change_type, version_id, tombstone_id,
			sync_root_id, object_id, created_at
		)
		VALUES (?, ?, 'delete', '', ?, ?, ?, ?)
	`, newID(), userID, tombstoneID, syncRootID, objectID, createdAt)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return map[string]string{
		"id":           tombstoneID,
		"change_type":  "delete",
		"object_id":    objectID,
		"sync_root_id": syncRootID,
		"created_at":   createdAt,
	}, nil
}
