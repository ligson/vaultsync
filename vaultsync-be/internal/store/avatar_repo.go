package store

import (
	"context"
	"database/sql"
	"errors"

	"github.com/ligson/vaultsync/internal/domain"
)

type AvatarRepo struct {
	db *sql.DB
}

func NewAvatarRepo(db *sql.DB) *AvatarRepo {
	return &AvatarRepo{db: db}
}

func (r *AvatarRepo) Find(ctx context.Context, userID string) (domain.UserAvatar, error) {
	var avatar domain.UserAvatar
	err := r.db.QueryRowContext(ctx, `
		SELECT user_id, content_hash, size_bytes, updated_at
		FROM user_avatars
		WHERE user_id = ?
	`, userID).Scan(
		&avatar.UserID,
		&avatar.ContentHash,
		&avatar.SizeBytes,
		&avatar.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.UserAvatar{}, ErrNotFound
	}
	if err != nil {
		return domain.UserAvatar{}, err
	}
	return avatar, nil
}

func (r *AvatarRepo) Upsert(
	ctx context.Context,
	avatar domain.UserAvatar,
	contentPath string,
) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO user_avatars (
			user_id, content_path, content_hash, size_bytes, updated_at
		)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
			content_path = excluded.content_path,
			content_hash = excluded.content_hash,
			size_bytes = excluded.size_bytes,
			updated_at = excluded.updated_at
	`, avatar.UserID, contentPath, avatar.ContentHash, avatar.SizeBytes, avatar.UpdatedAt)
	return err
}
