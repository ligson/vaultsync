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
	rows, err := s.queryChanges(ctx, userID, cursorDeviceID, startCursor, limit)
	if err != nil {
		return domain.ChangePage{}, err
	}
	defer rows.Close()

	items := make([]domain.CursorChange, 0)
	var nextCursor int64 = cursorValue
	for rows.Next() {
		var change domain.CursorChange
		var encryptedName sql.NullString
		var contentHash sql.NullString
		var sizeBytes sql.NullInt64
		var metadataJSON sql.NullString
		if err := rows.Scan(
			&change.CursorValue,
			&change.ChangeType,
			&change.VersionID,
			&change.ObjectID,
			&change.SyncRootID,
			&encryptedName,
			&contentHash,
			&sizeBytes,
			&metadataJSON,
			&change.CreatedAt,
		); err != nil {
			return domain.ChangePage{}, err
		}
		if encryptedName.Valid {
			change.EncryptedName = encryptedName.String
		}
		if contentHash.Valid {
			change.ContentHash = contentHash.String
		}
		if sizeBytes.Valid {
			change.SizeBytes = sizeBytes.Int64
		}
		if metadataJSON.Valid {
			change.MetadataJSON = metadataJSON.String
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

func (s *ChangeService) queryChanges(ctx context.Context, userID, cursorDeviceID string, startCursor int64, limit int) (*sql.Rows, error) {
	if cursorDeviceID == legacyCursorDeviceID {
		return s.db.QueryContext(ctx, `
			SELECT se.rowid, se.change_type, se.version_id, se.object_id, se.sync_root_id,
				COALESCE(fv.encrypted_name, ''), COALESCE(fv.content_hash, ''),
				COALESCE(fv.size_bytes, 0), COALESCE(fv.metadata_json, ''), se.created_at
			FROM sync_events se
			LEFT JOIN file_versions fv ON fv.user_id = se.user_id AND fv.id = se.version_id
			WHERE se.user_id = ? AND se.rowid > ?
			ORDER BY se.rowid
			LIMIT ?
		`, userID, startCursor, limit+1)
	}
	return s.db.QueryContext(ctx, `
		SELECT se.rowid, se.change_type, se.version_id, se.object_id, se.sync_root_id,
			COALESCE(fv.encrypted_name, ''), COALESCE(fv.content_hash, ''),
			COALESCE(fv.size_bytes, 0), COALESCE(fv.metadata_json, ''), se.created_at
		FROM sync_events se
		JOIN sync_roots sr ON sr.id = se.sync_root_id AND sr.user_id = se.user_id
		LEFT JOIN file_versions fv ON fv.user_id = se.user_id AND fv.id = se.version_id
		WHERE se.user_id = ? AND sr.device_id = ? AND se.rowid > ?
		ORDER BY se.rowid
		LIMIT ?
	`, userID, cursorDeviceID, startCursor, limit+1)
}

func normalizeChangeLimit(limit int) (int, error) {
	if limit < 0 {
		return 0, InvalidRequest("分页大小必须是正整数")
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
		return "", InvalidRequest("设备不属于当前用户")
	}
	return deviceID, nil
}
