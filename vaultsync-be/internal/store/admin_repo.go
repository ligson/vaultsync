package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
)

type AdminRepo struct {
	db *sql.DB
}

func NewAdminRepo(db *sql.DB) *AdminRepo {
	return &AdminRepo{db: db}
}

func (r *AdminRepo) Overview(ctx context.Context) (domain.AdminOverview, error) {
	var overview domain.AdminOverview
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&overview.UserCount); err != nil {
		return overview, err
	}
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&overview.DeviceCount); err != nil {
		return overview, err
	}
	if err := r.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size_bytes), 0) FROM file_versions`).Scan(&overview.StorageBytes); err != nil {
		return overview, err
	}
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM audit_logs WHERE action LIKE '%error%'`).Scan(&overview.RecentErrorCount); err != nil {
		return overview, err
	}
	events, err := r.RecentAuditLogs(ctx, 8)
	if err != nil {
		return overview, err
	}
	overview.RecentEvents = events
	return overview, nil
}

func (r *AdminRepo) Users(ctx context.Context) ([]domain.User, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, email, password_hash, role, status, quota_bytes, used_bytes, created_at
		FROM users
		ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []domain.User
	for rows.Next() {
		var user domain.User
		if err := rows.Scan(&user.ID, &user.Email, &user.PasswordHash, &user.Role, &user.Status, &user.QuotaBytes, &user.UsedBytes, &user.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	return users, rows.Err()
}

func (r *AdminRepo) UpdateUser(ctx context.Context, userID, status string, quotaBytes int64) (domain.User, error) {
	result, err := r.db.ExecContext(ctx, `
		UPDATE users
		SET status = ?, quota_bytes = ?
		WHERE id = ?
	`, status, quotaBytes, userID)
	if err != nil {
		return domain.User{}, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return domain.User{}, err
	}
	if affected == 0 {
		return domain.User{}, ErrNotFound
	}
	authRepo := NewAuthRepo(r.db)
	return authRepo.FindUserByID(ctx, userID)
}

func (r *AdminRepo) InsertAuditLog(ctx context.Context, log domain.AuditLog) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO audit_logs (id, user_id, action, details_json, created_at)
		VALUES (?, ?, ?, ?, ?)
	`, log.ID, log.UserID, log.Action, log.DetailsJSON, log.CreatedAt)
	return err
}

func (r *AdminRepo) RecentAuditLogs(ctx context.Context, limit int) ([]domain.AuditLog, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, user_id, action, details_json, created_at
		FROM audit_logs
		ORDER BY created_at DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	logs := []domain.AuditLog{}
	for rows.Next() {
		var log domain.AuditLog
		if err := rows.Scan(&log.ID, &log.UserID, &log.Action, &log.DetailsJSON, &log.CreatedAt); err != nil {
			return nil, err
		}
		logs = append(logs, log)
	}
	return logs, rows.Err()
}

func (r *AdminRepo) AuditLogs(ctx context.Context, limit int) ([]domain.AuditLog, error) {
	return r.RecentAuditLogs(ctx, limit)
}

func (r *AdminRepo) CountUsers(ctx context.Context) (int64, error) {
	var count int64
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&count)
	return count, err
}

func (r *AdminRepo) CountDevices(ctx context.Context) (int64, error) {
	var count int64
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices`).Scan(&count)
	return count, err
}

func (r *AdminRepo) Settings(ctx context.Context) (map[string]string, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key, value FROM system_settings ORDER BY key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	settings := map[string]string{}
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			return nil, err
		}
		settings[key] = value
	}
	return settings, rows.Err()
}

func (r *AdminRepo) UpsertSettings(ctx context.Context, values map[string]string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for key, value := range values {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO system_settings (key, value, updated_at)
			VALUES (?, ?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
		`, key, value, now); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (r *AdminRepo) Downloads(ctx context.Context) ([]domain.DownloadRelease, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT platform, file_name, version, download_url, size_bytes, updated_at
		FROM download_releases
		ORDER BY platform
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	merged := map[string]domain.DownloadRelease{}
	for _, release := range defaultDownloadReleases() {
		merged[release.Platform] = release
	}
	for rows.Next() {
		var release domain.DownloadRelease
		if err := rows.Scan(&release.Platform, &release.FileName, &release.Version, &release.DownloadURL, &release.SizeBytes, &release.UpdatedAt); err != nil {
			return nil, err
		}
		merged[release.Platform] = release
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	defaults := defaultDownloadReleases()
	releases := make([]domain.DownloadRelease, 0, len(defaults))
	for _, release := range defaults {
		releases = append(releases, merged[release.Platform])
	}
	return releases, nil
}

func (r *AdminRepo) UpsertDownload(ctx context.Context, release domain.DownloadRelease) (domain.DownloadRelease, error) {
	if release.UpdatedAt == "" {
		release.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO download_releases (platform, file_name, version, download_url, size_bytes, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(platform) DO UPDATE SET
			file_name = excluded.file_name,
			version = excluded.version,
			download_url = excluded.download_url,
			size_bytes = excluded.size_bytes,
			updated_at = excluded.updated_at
	`, release.Platform, release.FileName, release.Version, release.DownloadURL, release.SizeBytes, release.UpdatedAt)
	if err != nil {
		return domain.DownloadRelease{}, err
	}
	return release, nil
}

func (r *AdminRepo) DownloadByPlatform(ctx context.Context, platform string) (domain.DownloadRelease, error) {
	var release domain.DownloadRelease
	err := r.db.QueryRowContext(ctx, `
		SELECT platform, file_name, version, download_url, size_bytes, updated_at
		FROM download_releases
		WHERE platform = ?
	`, platform).Scan(&release.Platform, &release.FileName, &release.Version, &release.DownloadURL, &release.SizeBytes, &release.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.DownloadRelease{}, ErrNotFound
	}
	return release, err
}

func (r *AdminRepo) DeleteDownload(ctx context.Context, platform string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM download_releases WHERE platform = ?`, platform)
	return err
}

func (r *AdminRepo) UserRole(ctx context.Context, userID string) (string, error) {
	var role string
	err := r.db.QueryRowContext(ctx, `SELECT role FROM users WHERE id = ? AND status = 'active'`, userID).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return role, err
}

func defaultDownloadReleases() []domain.DownloadRelease {
	return []domain.DownloadRelease{
		{Platform: "macos", FileName: "vaultsync-macos-latest.dmg", Version: "1.0.0", DownloadURL: "/downloads/vaultsync-macos-latest.dmg", UpdatedAt: ""},
		{Platform: "windows", FileName: "vaultsync-windows-latest.exe", Version: "1.0.0", DownloadURL: "/downloads/vaultsync-windows-latest.exe", UpdatedAt: ""},
		{Platform: "android", FileName: "vaultsync-android-latest.apk", Version: "1.0.0", DownloadURL: "/downloads/vaultsync-android-latest.apk", UpdatedAt: ""},
		{Platform: "linux", FileName: "vaultsync-linux-latest.AppImage", Version: "1.0.0", DownloadURL: "/downloads/vaultsync-linux-latest.AppImage", UpdatedAt: ""},
	}
}
