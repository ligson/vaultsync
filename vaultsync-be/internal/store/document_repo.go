package store

import (
	"context"
	"database/sql"

	"github.com/ligson/vaultsync/internal/domain"
)

type DocumentRepo struct {
	db *sql.DB
}

func NewDocumentRepo(db *sql.DB) *DocumentRepo {
	return &DocumentRepo{db: db}
}

func (r *DocumentRepo) ListDevices(ctx context.Context, userID string) ([]domain.Device, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT DISTINCT d.id, d.name, d.platform
		FROM document_assets da
		JOIN devices d ON d.id = da.device_id AND d.user_id = da.user_id
		WHERE da.user_id = ?
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

func (r *DocumentRepo) ListItems(ctx context.Context, userID, documentType, deviceID, sortBy, order string, offset, limit int) ([]domain.DocumentAsset, error) {
	sortExpression := map[string]string{
		"time": "da.updated_at",
		"type": "da.document_type, da.document_format",
		"size": "fv.size_bytes",
	}[sortBy]
	if sortExpression == "" {
		sortExpression = "da.updated_at"
	}
	direction := "DESC"
	if order == "asc" {
		direction = "ASC"
	}
	query := `
		SELECT da.id, da.device_id, COALESCE(d.name, ''), da.sync_root_id,
			COALESCE(sr.encrypted_display_name, ''), sr.encrypted_path,
			da.object_id, da.version_id, fv.encrypted_name, fv.metadata_json,
			fv.content_hash, fv.size_bytes, da.document_type,
			da.document_format, da.updated_at
		FROM document_assets da
		JOIN file_versions fv ON fv.id = da.version_id AND fv.user_id = da.user_id
		JOIN sync_roots sr ON sr.id = da.sync_root_id AND sr.user_id = da.user_id
		LEFT JOIN devices d ON d.id = da.device_id AND d.user_id = da.user_id
		WHERE da.user_id = ?
			AND (? = '' OR da.document_type = ?)
			AND (? = '' OR da.device_id = ?)
			AND NOT EXISTS (
				SELECT 1 FROM file_tombstones ft
				WHERE ft.user_id = da.user_id
					AND ft.sync_root_id = da.sync_root_id
					AND ft.object_id = da.object_id
			)
		ORDER BY ` + sortExpression + ` ` + direction + `, da.id ` + direction + `
		LIMIT ? OFFSET ?`
	rows, err := r.db.QueryContext(ctx, query, userID, documentType, documentType,
		deviceID, deviceID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]domain.DocumentAsset, 0)
	for rows.Next() {
		var item domain.DocumentAsset
		if err := rows.Scan(&item.ID, &item.DeviceID, &item.DeviceName,
			&item.SyncRootID, &item.EncryptedRootDisplayName,
			&item.EncryptedRootPath, &item.ObjectID, &item.VersionID,
			&item.EncryptedName, &item.MetadataJSON, &item.ContentHash,
			&item.SizeBytes, &item.DocumentType, &item.DocumentFormat,
			&item.UpdatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *DocumentRepo) ListUnindexedCandidates(ctx context.Context, userID string, cursorValue int64, limit int) ([]domain.RemoteBackupObject, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT fv.rowid, fv.sync_root_id, fv.object_id, fv.id,
			fv.encrypted_name, fv.content_hash, fv.size_bytes,
			fv.metadata_json, fv.created_at
		FROM file_versions fv
		JOIN sync_roots sr ON sr.user_id = fv.user_id AND sr.id = fv.sync_root_id
		WHERE fv.user_id = ?
			AND fv.rowid > ?
			AND NOT EXISTS (
				SELECT 1 FROM file_versions newer
				WHERE newer.user_id = fv.user_id
					AND newer.sync_root_id = fv.sync_root_id
					AND newer.object_id = fv.object_id
					AND newer.rowid > fv.rowid
			)
			AND NOT EXISTS (
				SELECT 1 FROM document_index_marks dim
				WHERE dim.user_id = fv.user_id AND dim.version_id = fv.id
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
		if err := rows.Scan(&item.CursorValue, &item.SyncRootID, &item.ObjectID,
			&item.VersionID, &item.EncryptedName, &item.ContentHash,
			&item.SizeBytes, &item.MetadataJSON, &item.UpdatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *DocumentRepo) VersionExists(ctx context.Context, userID, syncRootID, objectID, versionID string) (bool, error) {
	var exists int
	err := r.db.QueryRowContext(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM file_versions
			WHERE user_id = ? AND sync_root_id = ? AND object_id = ? AND id = ?
		)
	`, userID, syncRootID, objectID, versionID).Scan(&exists)
	return exists != 0, err
}

func (r *DocumentRepo) VersionBelongsToUser(ctx context.Context, userID, versionID string) (bool, error) {
	var exists int
	err := r.db.QueryRowContext(ctx, `
		SELECT EXISTS(SELECT 1 FROM file_versions WHERE user_id = ? AND id = ?)
	`, userID, versionID).Scan(&exists)
	return exists != 0, err
}

func (r *DocumentRepo) GetIDForObject(ctx context.Context, userID, syncRootID, objectID string) (string, error) {
	var documentID string
	err := r.db.QueryRowContext(ctx, `
		SELECT id FROM document_assets
		WHERE user_id = ? AND sync_root_id = ? AND object_id = ?
	`, userID, syncRootID, objectID).Scan(&documentID)
	if err == sql.ErrNoRows {
		return "", ErrNotFound
	}
	return documentID, err
}

func (r *DocumentRepo) InsertBackfill(ctx context.Context, userID string, items []domain.DocumentAsset, ignoredVersionIDs []string, indexedAt string) (int, int, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()
	indexed := 0
	marked := 0
	for _, item := range items {
		var existingVersionID string
		existingErr := tx.QueryRowContext(ctx, `
			SELECT version_id FROM document_assets
			WHERE user_id = ? AND sync_root_id = ? AND object_id = ?
		`, userID, item.SyncRootID, item.ObjectID).Scan(&existingVersionID)
		if existingErr != nil && existingErr != sql.ErrNoRows {
			return 0, 0, existingErr
		}
		result, err := tx.ExecContext(ctx, `
			INSERT INTO document_assets (
				id, user_id, device_id, sync_root_id, object_id, version_id,
				document_type, document_format, updated_at
			)
			SELECT ?, ?, sr.device_id, ?, ?, ?, ?, ?, ?
			FROM sync_roots sr
			WHERE sr.user_id = ? AND sr.id = ?
			ON CONFLICT(user_id, sync_root_id, object_id) DO UPDATE SET
				device_id = excluded.device_id,
				version_id = excluded.version_id,
				document_type = excluded.document_type,
				document_format = excluded.document_format,
				updated_at = excluded.updated_at
		`, item.ID, userID, item.SyncRootID, item.ObjectID, item.VersionID,
			item.DocumentType, item.DocumentFormat, item.UpdatedAt, userID,
			item.SyncRootID)
		if err != nil {
			return 0, 0, err
		}
		if _, err := result.RowsAffected(); err != nil {
			return 0, 0, err
		}
		if existingErr == sql.ErrNoRows || existingVersionID != item.VersionID {
			indexed++
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO document_index_marks (user_id, version_id, indexed_at)
			VALUES (?, ?, ?)
			ON CONFLICT(user_id, version_id) DO NOTHING
		`, userID, item.VersionID, indexedAt); err != nil {
			return 0, 0, err
		}
		marked++
	}
	for _, versionID := range ignoredVersionIDs {
		result, err := tx.ExecContext(ctx, `
			INSERT INTO document_index_marks (user_id, version_id, indexed_at)
			SELECT ?, fv.id, ? FROM file_versions fv
			WHERE fv.user_id = ? AND fv.id = ?
			ON CONFLICT(user_id, version_id) DO NOTHING
		`, userID, indexedAt, userID, versionID)
		if err != nil {
			return 0, 0, err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return 0, 0, err
		}
		marked += int(count)
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return indexed, marked, nil
}
