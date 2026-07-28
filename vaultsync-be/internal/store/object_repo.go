package store

import (
	"context"
	"database/sql"
	"errors"

	"github.com/ligson/vaultsync/internal/domain"
)

type ObjectRepo struct {
	db *sql.DB
}

func NewObjectRepo(db *sql.DB) *ObjectRepo {
	return &ObjectRepo{db: db}
}

func (r *ObjectRepo) CreateUploadSession(ctx context.Context, session domain.UploadSession) (domain.UploadSession, error) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO upload_sessions (
			id, user_id, device_id, sync_root_id, object_id, version_id,
			total_size, chunk_size, received_size, status, metadata_json, created_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, session.ID, session.UserID, session.DeviceID, session.SyncRootID, session.ObjectID, session.VersionID, session.TotalSize, session.ChunkSize, session.ReceivedSize, session.Status, session.MetadataJSON, session.CreatedAt)
	if err != nil {
		return domain.UploadSession{}, err
	}
	return session, nil
}

func (r *ObjectRepo) GetUploadSession(ctx context.Context, userID, sessionID string) (domain.UploadSession, error) {
	var session domain.UploadSession
	err := r.db.QueryRowContext(ctx, `
		SELECT id, user_id, device_id, sync_root_id, object_id, version_id,
			total_size, chunk_size, received_size, status, metadata_json, created_at
		FROM upload_sessions
		WHERE user_id = ? AND id = ?
	`, userID, sessionID).Scan(&session.ID, &session.UserID, &session.DeviceID, &session.SyncRootID, &session.ObjectID, &session.VersionID, &session.TotalSize, &session.ChunkSize, &session.ReceivedSize, &session.Status, &session.MetadataJSON, &session.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.UploadSession{}, ErrNotFound
	}
	if err != nil {
		return domain.UploadSession{}, err
	}
	return session, nil
}

func (r *ObjectRepo) GetFileVersion(ctx context.Context, userID, versionID string) (domain.FileVersion, error) {
	var version domain.FileVersion
	err := r.db.QueryRowContext(ctx, `
		SELECT id, user_id, sync_root_id, object_id, encrypted_name,
			content_path, content_hash, size_bytes, metadata_json, created_at
		FROM file_versions
		WHERE user_id = ? AND id = ?
	`, userID, versionID).Scan(&version.ID, &version.UserID, &version.SyncRootID, &version.ObjectID, &version.EncryptedName, &version.ContentPath, &version.ContentHash, &version.SizeBytes, &version.MetadataJSON, &version.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.FileVersion{}, ErrNotFound
	}
	if err != nil {
		return domain.FileVersion{}, err
	}
	return version, nil
}

func (r *ObjectRepo) AddReceivedBytes(ctx context.Context, userID, sessionID string, bytes int64) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE upload_sessions
		SET received_size = received_size + ?
		WHERE user_id = ? AND id = ?
	`, bytes, userID, sessionID)
	return err
}

func (r *ObjectRepo) CompleteUpload(ctx context.Context, sessionID string, version domain.FileVersion) (domain.FileVersion, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.FileVersion{}, err
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx, `
		INSERT INTO file_versions (
			id, user_id, sync_root_id, object_id, encrypted_name,
			content_path, content_hash, size_bytes, metadata_json, created_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, version.ID, version.UserID, version.SyncRootID, version.ObjectID, version.EncryptedName, version.ContentPath, version.ContentHash, version.SizeBytes, version.MetadataJSON, version.CreatedAt)
	if err != nil {
		return domain.FileVersion{}, err
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO sync_events (
			id, user_id, change_type, version_id, tombstone_id,
			sync_root_id, object_id, created_at
		)
		VALUES (?, ?, 'upsert', ?, '', ?, ?, ?)
	`, newStoreID(), version.UserID, version.ID, version.SyncRootID, version.ObjectID, version.CreatedAt)
	if err != nil {
		return domain.FileVersion{}, err
	}

	_, err = tx.ExecContext(ctx, `
		UPDATE upload_sessions
		SET status = 'completed', received_size = ?
		WHERE user_id = ? AND id = ?
	`, version.SizeBytes, version.UserID, sessionID)
	if err != nil {
		return domain.FileVersion{}, err
	}

	if err := tx.Commit(); err != nil {
		return domain.FileVersion{}, err
	}
	return version, nil
}

func (r *ObjectRepo) ListRemoteBackupObjects(ctx context.Context, userID, syncRootID string, cursorValue int64, limit int) ([]domain.RemoteBackupObject, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT fv.rowid, fv.sync_root_id, fv.object_id, fv.id,
			fv.encrypted_name, fv.content_hash, fv.size_bytes, fv.metadata_json, fv.created_at
		FROM file_versions fv
		JOIN (
			SELECT object_id, MAX(rowid) AS latest_rowid
			FROM file_versions
			WHERE user_id = ? AND sync_root_id = ?
			GROUP BY object_id
		) latest ON latest.latest_rowid = fv.rowid
		WHERE fv.user_id = ?
			AND fv.sync_root_id = ?
			AND fv.rowid > ?
			AND NOT EXISTS (
				SELECT 1
				FROM file_tombstones ft
				WHERE ft.user_id = fv.user_id
					AND ft.sync_root_id = fv.sync_root_id
					AND ft.object_id = fv.object_id
			)
		ORDER BY fv.rowid
		LIMIT ?
	`, userID, syncRootID, userID, syncRootID, cursorValue, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]domain.RemoteBackupObject, 0)
	for rows.Next() {
		var item domain.RemoteBackupObject
		if err := rows.Scan(&item.CursorValue, &item.SyncRootID, &item.ObjectID, &item.VersionID, &item.EncryptedName, &item.ContentHash, &item.SizeBytes, &item.MetadataJSON, &item.UpdatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}
