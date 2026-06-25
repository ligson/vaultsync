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
