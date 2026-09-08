package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/ligson/vaultsync/internal/domain"
)

type MediaRepo struct {
	db *sql.DB
}

func NewMediaRepo(db *sql.DB) *MediaRepo {
	return &MediaRepo{db: db}
}

func (r *MediaRepo) ListMonths(ctx context.Context, userID, mediaType, deviceID string) ([]domain.MediaMonth, error) {
	query := `
		SELECT ma.captured_year, ma.captured_month, COUNT(*)
		FROM media_assets ma
		WHERE ma.user_id = ?
			AND (? = '' OR ma.media_type = ?)
			AND (? = '' OR ma.device_id = ?)
			AND NOT EXISTS (
				SELECT 1 FROM file_tombstones ft
				WHERE ft.user_id = ma.user_id
					AND ft.sync_root_id = ma.sync_root_id
					AND ft.object_id = ma.object_id
			)
		GROUP BY ma.captured_year, ma.captured_month
		ORDER BY ma.captured_year DESC, ma.captured_month DESC`
	rows, err := r.db.QueryContext(ctx, query, userID, mediaType, mediaType, deviceID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]domain.MediaMonth, 0)
	for rows.Next() {
		var item domain.MediaMonth
		if err := rows.Scan(&item.Year, &item.Month, &item.Count); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *MediaRepo) ListDevices(ctx context.Context, userID string) ([]domain.Device, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT DISTINCT d.id, d.name, d.platform
		FROM media_assets ma
		JOIN devices d ON d.id = ma.device_id AND d.user_id = ma.user_id
		WHERE ma.user_id = ?
		ORDER BY d.name, d.id
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]domain.Device, 0)
	for rows.Next() {
		var item domain.Device
		if err := rows.Scan(&item.ID, &item.Name, &item.Platform); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *MediaRepo) ListItems(ctx context.Context, userID string, year, month int, mediaType, deviceID, cursorTime, cursorID string, limit int) ([]domain.MediaAsset, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT ma.id, ma.device_id, COALESCE(d.name, ''), ma.sync_root_id,
			ma.object_id, ma.version_id, fv.encrypted_name, fv.metadata_json,
			fv.content_hash, fv.size_bytes, ma.media_type, ma.captured_at,
			ma.width, ma.height, ma.duration_ms, ma.thumbnail_path <> ''
		FROM media_assets ma
		JOIN file_versions fv ON fv.id = ma.version_id AND fv.user_id = ma.user_id
		LEFT JOIN devices d ON d.id = ma.device_id AND d.user_id = ma.user_id
		WHERE ma.user_id = ?
			AND ma.captured_year = ? AND ma.captured_month = ?
			AND (? = '' OR ma.media_type = ?)
			AND (? = '' OR ma.device_id = ?)
			AND (? = '' OR ma.captured_at < ? OR (ma.captured_at = ? AND ma.id < ?))
			AND NOT EXISTS (
				SELECT 1 FROM file_tombstones ft
				WHERE ft.user_id = ma.user_id
					AND ft.sync_root_id = ma.sync_root_id
					AND ft.object_id = ma.object_id
			)
		ORDER BY ma.captured_at DESC, ma.id DESC
		LIMIT ?
	`, userID, year, month, mediaType, mediaType, deviceID, deviceID,
		cursorTime, cursorTime, cursorTime, cursorID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]domain.MediaAsset, 0)
	for rows.Next() {
		var item domain.MediaAsset
		if err := rows.Scan(&item.ID, &item.DeviceID, &item.DeviceName,
			&item.SyncRootID, &item.ObjectID, &item.VersionID,
			&item.EncryptedName, &item.MetadataJSON, &item.ContentHash,
			&item.SizeBytes, &item.MediaType, &item.CapturedAt, &item.Width,
			&item.Height, &item.DurationMS, &item.HasThumbnail); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *MediaRepo) GetForUser(ctx context.Context, userID, mediaID string) (domain.MediaAsset, error) {
	var item domain.MediaAsset
	err := r.db.QueryRowContext(ctx, `
		SELECT id, device_id, sync_root_id, object_id, version_id,
			media_type, captured_at, width, height, duration_ms,
			thumbnail_path <> ''
		FROM media_assets
		WHERE user_id = ? AND id = ?
	`, userID, mediaID).Scan(&item.ID, &item.DeviceID, &item.SyncRootID,
		&item.ObjectID, &item.VersionID, &item.MediaType, &item.CapturedAt,
		&item.Width, &item.Height, &item.DurationMS, &item.HasThumbnail)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.MediaAsset{}, ErrNotFound
	}
	return item, err
}

func (r *MediaRepo) GetIDForVersion(ctx context.Context, userID, versionID string) (string, error) {
	var mediaID string
	err := r.db.QueryRowContext(ctx, `
		SELECT id FROM media_assets WHERE user_id = ? AND version_id = ?
	`, userID, versionID).Scan(&mediaID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return mediaID, err
}

func (r *MediaRepo) GetIDForObject(ctx context.Context, userID, syncRootID, objectID string) (string, error) {
	var mediaID string
	err := r.db.QueryRowContext(ctx, `
		SELECT id FROM media_assets
		WHERE user_id = ? AND sync_root_id = ? AND object_id = ?
	`, userID, syncRootID, objectID).Scan(&mediaID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return mediaID, err
}

func (r *MediaRepo) SetThumbnail(ctx context.Context, userID, mediaID, path string, size int64, updatedAt string) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE media_assets
		SET thumbnail_path = ?, thumbnail_size_bytes = ?, updated_at = ?
		WHERE user_id = ? AND id = ?
	`, strings.TrimSpace(path), size, updatedAt, userID, mediaID)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return ErrNotFound
	}
	return nil
}

func (r *MediaRepo) VersionExists(ctx context.Context, userID, syncRootID, objectID, versionID string) (bool, error) {
	var exists int
	err := r.db.QueryRowContext(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM file_versions
			WHERE user_id = ? AND sync_root_id = ? AND object_id = ? AND id = ?
		)
	`, userID, syncRootID, objectID, versionID).Scan(&exists)
	return exists != 0, err
}

// ListUnindexedCandidates returns the latest live version of each media backup
// object that does not have a client-created media index yet.
func (r *MediaRepo) ListUnindexedCandidates(ctx context.Context, userID string, cursorValue int64, limit int) ([]domain.RemoteBackupObject, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT fv.rowid, fv.sync_root_id, fv.object_id, fv.id,
			fv.encrypted_name, fv.content_hash, fv.size_bytes, fv.metadata_json, fv.created_at
		FROM file_versions fv
		JOIN sync_roots sr ON sr.user_id = fv.user_id AND sr.id = fv.sync_root_id
		WHERE fv.user_id = ?
			AND sr.encrypted_path LIKE 'media-backup:v1:%'
			AND fv.rowid > ?
			AND NOT EXISTS (
				SELECT 1 FROM file_versions newer
				WHERE newer.user_id = fv.user_id
					AND newer.sync_root_id = fv.sync_root_id
					AND newer.object_id = fv.object_id
					AND newer.rowid > fv.rowid
			)
			AND NOT EXISTS (
				SELECT 1 FROM media_assets ma
				WHERE ma.user_id = fv.user_id
					AND ma.sync_root_id = fv.sync_root_id
					AND ma.object_id = fv.object_id
			)
			AND NOT EXISTS (
				SELECT 1 FROM file_tombstones ft
				WHERE ft.user_id = fv.user_id
					AND ft.sync_root_id = fv.sync_root_id
					AND ft.object_id = fv.object_id
			)
		ORDER BY fv.rowid
		LIMIT ?
	`, userID, cursorValue, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]domain.RemoteBackupObject, 0)
	for rows.Next() {
		var item domain.RemoteBackupObject
		if err := rows.Scan(&item.CursorValue, &item.SyncRootID, &item.ObjectID, &item.VersionID,
			&item.EncryptedName, &item.ContentHash, &item.SizeBytes, &item.MetadataJSON, &item.UpdatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *MediaRepo) InsertBackfill(ctx context.Context, userID string, items []domain.MediaAsset) (int, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	inserted := 0
	for _, item := range items {
		result, err := tx.ExecContext(ctx, `
			INSERT INTO media_assets (
				id, user_id, device_id, sync_root_id, object_id, version_id,
				media_type, captured_at, captured_year, captured_month,
				width, height, duration_ms, thumbnail_path,
				thumbnail_size_bytes, updated_at
			)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', 0, ?)
			ON CONFLICT(user_id, sync_root_id, object_id) DO NOTHING
		`, item.ID, userID, item.DeviceID, item.SyncRootID, item.ObjectID,
			item.VersionID, item.MediaType, item.CapturedAt,
			item.CapturedYear, item.CapturedMonth, item.Width,
			item.Height, item.DurationMS, item.CapturedAt)
		if err != nil {
			return 0, err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		inserted += int(count)
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return inserted, nil
}
