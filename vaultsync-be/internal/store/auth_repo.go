package store

import (
	"context"
	"database/sql"
	"errors"

	"github.com/ligson/vaultsync/internal/domain"
)

var ErrNotFound = errors.New("not found")

type AuthRepo struct {
	db *sql.DB
}

func NewAuthRepo(db *sql.DB) *AuthRepo {
	return &AuthRepo{db: db}
}

func (r *AuthRepo) CreateUser(ctx context.Context, user domain.User) (domain.User, error) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO users (id, email, password_hash, role, status, quota_bytes, used_bytes, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, user.ID, user.Email, user.PasswordHash, user.Role, user.Status, user.QuotaBytes, user.UsedBytes, user.CreatedAt)
	if err != nil {
		return domain.User{}, err
	}
	return user, nil
}

func (r *AuthRepo) FindUserByEmail(ctx context.Context, email string) (domain.User, error) {
	var user domain.User
	err := r.db.QueryRowContext(ctx, `
		SELECT id, email, password_hash, role, status, quota_bytes, used_bytes, created_at
		FROM users
		WHERE email = ?
	`, email).Scan(&user.ID, &user.Email, &user.PasswordHash, &user.Role, &user.Status, &user.QuotaBytes, &user.UsedBytes, &user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.User{}, ErrNotFound
	}
	if err != nil {
		return domain.User{}, err
	}
	return user, nil
}

func (r *AuthRepo) FindUserByID(ctx context.Context, id string) (domain.User, error) {
	var user domain.User
	err := r.db.QueryRowContext(ctx, `
		SELECT id, email, password_hash, role, status, quota_bytes, used_bytes, created_at
		FROM users
		WHERE id = ?
	`, id).Scan(&user.ID, &user.Email, &user.PasswordHash, &user.Role, &user.Status, &user.QuotaBytes, &user.UsedBytes, &user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.User{}, ErrNotFound
	}
	if err != nil {
		return domain.User{}, err
	}
	return user, nil
}

func (r *AuthRepo) CreateSession(ctx context.Context, tokenID, userID, deviceID, createdAt, expiresAt string) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO sessions (token_id, user_id, device_id, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?)
	`, tokenID, userID, deviceID, createdAt, expiresAt)
	return err
}

func (r *AuthRepo) UpdatePasswordHash(ctx context.Context, userID, passwordHash string) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE users
		SET password_hash = ?
		WHERE id = ?
	`, passwordHash, userID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return ErrNotFound
	}
	return nil
}
