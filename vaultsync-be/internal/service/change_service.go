package service

import (
	"context"
	"database/sql"
	"strings"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

type ChangeService struct {
	db         *sql.DB
	deviceRepo *store.DeviceRepo
}

const legacyCursorDeviceID = "__legacy__"
const DefaultChangeLimit = 100
const MaxChangeLimit = 500

func NewChangeService(db *sql.DB, deviceRepo *store.DeviceRepo, dataDir string) *ChangeService {
	_ = dataDir
	return &ChangeService{db: db, deviceRepo: deviceRepo}
}

func (s *ChangeService) List(ctx context.Context, userID, deviceID string, cursorValue int64, limit int) (domain.ChangePage, error) {
	limit, err := normalizeChangeLimit(limit)
	if err != nil {
		return domain.ChangePage{}, err
	}
	cursorDeviceID, err := s.cursorDeviceID(ctx, userID, deviceID)
	if err != nil {
		return domain.ChangePage{}, err
	}
	startCursor := cursorValue
	rows, err := s.db.QueryContext(ctx, `
		SELECT rowid, change_type, version_id, object_id, sync_root_id, created_at
		FROM sync_events
		WHERE user_id = ? AND rowid > ?
		ORDER BY rowid
		LIMIT ?
	`, userID, startCursor, limit+1)
	if err != nil {
		return domain.ChangePage{}, err
	}
	defer rows.Close()

	items := make([]domain.CursorChange, 0)
	var nextCursor int64 = cursorValue
	for rows.Next() {
		var change domain.CursorChange
		if err := rows.Scan(&change.CursorValue, &change.ChangeType, &change.VersionID, &change.ObjectID, &change.SyncRootID, &change.CreatedAt); err != nil {
			return domain.ChangePage{}, err
		}
		nextCursor = change.CursorValue
		items = append(items, change)
	}
	if err := rows.Err(); err != nil {
		return domain.ChangePage{}, err
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
		nextCursor = items[len(items)-1].CursorValue
	}

	if len(items) > 0 && nextCursor > startCursor {
		_, err := s.db.ExecContext(ctx, `
			INSERT INTO sync_cursors (user_id, device_id, cursor_value, version_id, created_at)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(user_id, device_id) DO UPDATE SET
				cursor_value = excluded.cursor_value,
				version_id = excluded.version_id,
				created_at = excluded.created_at
		`, userID, cursorDeviceID, nextCursor, items[len(items)-1].VersionID, items[len(items)-1].CreatedAt)
		if err != nil {
			return domain.ChangePage{}, err
		}
	}
	return domain.ChangePage{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func normalizeChangeLimit(limit int) (int, error) {
	if limit < 0 {
		return 0, InvalidRequest("limit must be positive")
	}
	if limit == 0 {
		return DefaultChangeLimit, nil
	}
	if limit > MaxChangeLimit {
		return MaxChangeLimit, nil
	}
	return limit, nil
}

func (s *ChangeService) cursorDeviceID(ctx context.Context, userID, deviceID string) (string, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return legacyCursorDeviceID, nil
	}
	exists, err := s.deviceRepo.ExistsForUser(ctx, userID, deviceID)
	if err != nil {
		return "", err
	}
	if !exists {
		return "", InvalidRequest("device does not belong to user")
	}
	return deviceID, nil
}
