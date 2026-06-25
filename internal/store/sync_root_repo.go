package store

import (
	"context"
	"database/sql"

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
