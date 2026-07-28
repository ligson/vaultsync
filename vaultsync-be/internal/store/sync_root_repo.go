package store

import (
	"context"
	"database/sql"
	"errors"

	"github.com/ligson/vaultsync/internal/domain"
)

type SyncRootRepo struct {
	db *sql.DB
}

func NewSyncRootRepo(db *sql.DB) *SyncRootRepo {
	return &SyncRootRepo{db: db}
}

func (r *SyncRootRepo) Create(ctx context.Context, root domain.SyncRoot) (domain.SyncRoot, error) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO sync_roots (id, user_id, device_id, encrypted_path, cleanup_policy, archive_path, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, root.ID, root.UserID, root.DeviceID, root.EncryptedPath, root.CleanupPolicy, root.ArchivePath, root.CreatedAt)
	if err != nil {
		return domain.SyncRoot{}, err
	}
	return root, nil
}

func (r *SyncRootRepo) GetForUser(ctx context.Context, userID, rootID string) (domain.SyncRoot, error) {
	var root domain.SyncRoot
	err := r.db.QueryRowContext(ctx, `
		SELECT id, user_id, device_id, encrypted_path, cleanup_policy, archive_path, created_at
		FROM sync_roots
		WHERE user_id = ? AND id = ?
	`, userID, rootID).Scan(&root.ID, &root.UserID, &root.DeviceID, &root.EncryptedPath, &root.CleanupPolicy, &root.ArchivePath, &root.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.SyncRoot{}, ErrNotFound
	}
	if err != nil {
		return domain.SyncRoot{}, err
	}
	return root, nil
}

func (r *SyncRootRepo) ListByUser(ctx context.Context, userID string) ([]domain.SyncRoot, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, user_id, device_id, encrypted_path, cleanup_policy, archive_path, created_at
		FROM sync_roots
		WHERE user_id = ?
		ORDER BY created_at, id
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	roots := make([]domain.SyncRoot, 0)
	for rows.Next() {
		var root domain.SyncRoot
		if err := rows.Scan(&root.ID, &root.UserID, &root.DeviceID, &root.EncryptedPath, &root.CleanupPolicy, &root.ArchivePath, &root.CreatedAt); err != nil {
			return nil, err
		}
		roots = append(roots, root)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return roots, nil
}

func (r *SyncRootRepo) UpdateCleanupPolicy(ctx context.Context, userID, rootID, cleanupPolicy, archivePath string) (domain.SyncRoot, error) {
	result, err := r.db.ExecContext(ctx, `
		UPDATE sync_roots
		SET cleanup_policy = ?, archive_path = ?
		WHERE user_id = ? AND id = ?
	`, cleanupPolicy, archivePath, userID, rootID)
	if err != nil {
		return domain.SyncRoot{}, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return domain.SyncRoot{}, err
	}
	if affected == 0 {
		return domain.SyncRoot{}, ErrNotFound
	}
	return r.GetForUser(ctx, userID, rootID)
}

func (r *SyncRootRepo) DeleteForUser(ctx context.Context, userID, rootID, deviceID string, deleteRemote bool, createdAt string) (int, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	deletedObjects := 0
	if deleteRemote {
		objectIDs := make([]string, 0)
		rows, err := tx.QueryContext(ctx, `
			SELECT DISTINCT fv.object_id
			FROM file_versions fv
			WHERE fv.user_id = ? AND fv.sync_root_id = ?
				AND NOT EXISTS (
					SELECT 1
					FROM file_tombstones ft
					WHERE ft.user_id = fv.user_id
						AND ft.sync_root_id = fv.sync_root_id
						AND ft.object_id = fv.object_id
				)
			ORDER BY fv.object_id
		`, userID, rootID)
		if err != nil {
			return 0, err
		}

		for rows.Next() {
			var objectID string
			if err := rows.Scan(&objectID); err != nil {
				_ = rows.Close()
				return 0, err
			}
			objectIDs = append(objectIDs, objectID)
		}
		if err := rows.Close(); err != nil {
			return 0, err
		}
		if err := rows.Err(); err != nil {
			return 0, err
		}

		for _, objectID := range objectIDs {
			tombstoneID := newStoreID()
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO file_tombstones (id, user_id, device_id, sync_root_id, object_id, metadata_json, created_at)
				VALUES (?, ?, ?, ?, ?, ?, ?)
			`, tombstoneID, userID, deviceID, rootID, objectID, `{}`, createdAt); err != nil {
				return 0, err
			}
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO sync_events (
					id, user_id, change_type, version_id, tombstone_id,
					sync_root_id, object_id, created_at
				)
				VALUES (?, ?, 'delete', '', ?, ?, ?, ?)
			`, newStoreID(), userID, tombstoneID, rootID, objectID, createdAt); err != nil {
				return 0, err
			}
			deletedObjects++
		}
	}

	result, err := tx.ExecContext(ctx, `
		DELETE FROM sync_roots
		WHERE user_id = ? AND id = ?
	`, userID, rootID)
	if err != nil {
		return 0, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if affected == 0 {
		return 0, ErrNotFound
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deletedObjects, nil
}
