package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/ligson/vaultsync/internal/domain"
)

var (
	ErrNotFound          = errors.New("not found")
	ErrDuplicateEmail    = errors.New("duplicate email")
	ErrDuplicateUsername = errors.New("duplicate username")
)

type AuthRepo struct {
	db *sql.DB
}

func NewAuthRepo(db *sql.DB) *AuthRepo {
	return &AuthRepo{db: db}
}

func (r *AuthRepo) CreateUser(ctx context.Context, user domain.User) (domain.User, error) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO users (id, email, username, nickname, password_hash, role, status, quota_bytes, used_bytes, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, user.ID, user.Email, user.Username, user.Nickname, user.PasswordHash, user.Role, user.Status, user.QuotaBytes, user.UsedBytes, user.CreatedAt)
	if err != nil {
		if isDuplicateEmailError(err) {
			return domain.User{}, ErrDuplicateEmail
		}
		return domain.User{}, err
	}
	return user, nil
}

func isDuplicateEmailError(err error) bool {
	message := err.Error()
	return strings.Contains(message, "UNIQUE constraint failed") &&
		strings.Contains(message, "users.email")
}

func (r *AuthRepo) FindUserByEmail(ctx context.Context, email string) (domain.User, error) {
	var user domain.User
	err := r.db.QueryRowContext(ctx, `
		SELECT id, email, username, nickname, password_hash, role, status, quota_bytes, used_bytes, created_at
		FROM users
		WHERE email = ?
	`, email).Scan(&user.ID, &user.Email, &user.Username, &user.Nickname, &user.PasswordHash, &user.Role, &user.Status, &user.QuotaBytes, &user.UsedBytes, &user.CreatedAt)
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
		SELECT id, email, username, nickname, password_hash, role, status, quota_bytes, used_bytes, created_at
		FROM users
		WHERE id = ?
	`, id).Scan(&user.ID, &user.Email, &user.Username, &user.Nickname, &user.PasswordHash, &user.Role, &user.Status, &user.QuotaBytes, &user.UsedBytes, &user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.User{}, ErrNotFound
	}
	if err != nil {
		return domain.User{}, err
	}
	return user, nil
}

func (r *AuthRepo) StorageUsage(ctx context.Context, userID string) (domain.StorageUsage, error) {
	var usage domain.StorageUsage
	if err := r.db.QueryRowContext(ctx, `
		SELECT quota_bytes
		FROM users
		WHERE id = ?
	`, userID).Scan(&usage.QuotaBytes); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.StorageUsage{}, ErrNotFound
		}
		return domain.StorageUsage{}, err
	}

	rows, err := r.db.QueryContext(ctx, `
		WITH latest_versions AS (
			SELECT fv.sync_root_id, fv.object_id, fv.size_bytes
			FROM file_versions fv
			JOIN (
				SELECT sync_root_id, object_id, MAX(rowid) AS latest_rowid
				FROM file_versions
				WHERE user_id = ?
				GROUP BY sync_root_id, object_id
			) latest ON latest.latest_rowid = fv.rowid
			WHERE fv.user_id = ?
				AND NOT EXISTS (
					SELECT 1
					FROM file_tombstones ft
					WHERE ft.user_id = fv.user_id
						AND ft.sync_root_id = fv.sync_root_id
						AND ft.object_id = fv.object_id
				)
		)
		SELECT d.id, d.name, d.platform,
			sr.id, sr.encrypted_path,
			COALESCE(SUM(lv.size_bytes), 0), COUNT(lv.object_id)
		FROM devices d
		LEFT JOIN sync_roots sr
			ON sr.user_id = d.user_id AND sr.device_id = d.id
		LEFT JOIN latest_versions lv ON lv.sync_root_id = sr.id
		WHERE d.user_id = ?
		GROUP BY d.id, d.name, d.platform, sr.id, sr.encrypted_path
		ORDER BY d.created_at, sr.created_at
	`, userID, userID, userID)
	if err != nil {
		return domain.StorageUsage{}, err
	}
	defer rows.Close()

	devicesByID := make(map[string]int)
	usage.Devices = make([]domain.DeviceStorageUsage, 0)
	for rows.Next() {
		var deviceID, deviceName, platform string
		var rootID, encryptedPath sql.NullString
		var usedBytes, fileCount int64
		if err := rows.Scan(
			&deviceID, &deviceName, &platform,
			&rootID, &encryptedPath, &usedBytes, &fileCount,
		); err != nil {
			return domain.StorageUsage{}, err
		}
		index, ok := devicesByID[deviceID]
		if !ok {
			index = len(usage.Devices)
			devicesByID[deviceID] = index
			usage.Devices = append(usage.Devices, domain.DeviceStorageUsage{
				DeviceID: deviceID, DeviceName: deviceName, Platform: platform,
				SyncRoots: make([]domain.SyncRootStorageUsage, 0),
			})
		}
		if rootID.Valid {
			usage.Devices[index].SyncRoots = append(usage.Devices[index].SyncRoots, domain.SyncRootStorageUsage{
				SyncRootID: rootID.String, EncryptedPath: encryptedPath.String,
				UsedBytes: usedBytes, FileCount: fileCount,
			})
			usage.Devices[index].UsedBytes += usedBytes
			usage.UsedBytes += usedBytes
		}
	}
	if err := rows.Err(); err != nil {
		return domain.StorageUsage{}, err
	}
	return usage, nil
}

func (r *AuthRepo) UpdateProfile(ctx context.Context, userID, username, nickname string) (domain.User, error) {
	_, err := r.db.ExecContext(ctx, `
		UPDATE users
		SET username = ?, nickname = ?
		WHERE id = ?
	`, username, nickname, userID)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") && strings.Contains(err.Error(), "users.username") {
			return domain.User{}, ErrDuplicateUsername
		}
		return domain.User{}, err
	}
	return r.FindUserByID(ctx, userID)
}

func (r *AuthRepo) CreateSession(
	ctx context.Context,
	tokenID, userID, deviceID, createdAt, expiresAt, refreshTokenHash, refreshExpiresAt string,
) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO sessions (
			token_id, user_id, device_id, created_at, expires_at,
			refresh_token_hash, refresh_expires_at, revoked_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, '')
	`, tokenID, userID, deviceID, createdAt, expiresAt, refreshTokenHash, refreshExpiresAt)
	return err
}

func (r *AuthRepo) FindSessionByRefreshTokenHash(ctx context.Context, refreshTokenHash string) (domain.RefreshSession, error) {
	var session domain.RefreshSession
	err := r.db.QueryRowContext(ctx, `
		SELECT token_id, user_id, COALESCE(device_id, ''), refresh_expires_at, revoked_at
		FROM sessions
		WHERE refresh_token_hash = ?
	`, refreshTokenHash).Scan(
		&session.TokenID,
		&session.UserID,
		&session.DeviceID,
		&session.RefreshExpiresAt,
		&session.RevokedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.RefreshSession{}, ErrNotFound
	}
	if err != nil {
		return domain.RefreshSession{}, err
	}
	return session, nil
}

func (r *AuthRepo) RotateRefreshToken(
	ctx context.Context,
	tokenID, oldRefreshTokenHash, newRefreshTokenHash, accessExpiresAt string,
) error {
	result, err := r.db.ExecContext(ctx, `
		UPDATE sessions
		SET refresh_token_hash = ?, expires_at = ?
		WHERE token_id = ? AND refresh_token_hash = ? AND revoked_at = ''
	`, newRefreshTokenHash, accessExpiresAt, tokenID, oldRefreshTokenHash)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected != 1 {
		return ErrNotFound
	}
	return nil
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
