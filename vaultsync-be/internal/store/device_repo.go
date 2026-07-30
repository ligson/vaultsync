package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/ligson/vaultsync/internal/domain"
)

type DeviceRepo struct {
	db *sql.DB
}

func NewDeviceRepo(db *sql.DB) *DeviceRepo {
	return &DeviceRepo{db: db}
}

func (r *DeviceRepo) Create(ctx context.Context, device domain.Device) (domain.Device, error) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO devices (id, user_id, name, platform, client_key, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, device.ID, device.UserID, device.Name, device.Platform, device.ClientKey, device.CreatedAt)
	if err != nil {
		return domain.Device{}, err
	}
	return device, nil
}

func (r *DeviceRepo) FindByClientKey(ctx context.Context, userID, clientKey string) (domain.Device, bool, error) {
	var device domain.Device
	err := r.db.QueryRowContext(ctx, `
		SELECT id, user_id, name, platform, client_key, created_at
		FROM devices
		WHERE user_id = ? AND client_key = ? AND client_key <> ''
	`, userID, clientKey).Scan(&device.ID, &device.UserID, &device.Name, &device.Platform, &device.ClientKey, &device.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Device{}, false, nil
	}
	if err != nil {
		return domain.Device{}, false, err
	}
	return device, true, nil
}

func (r *DeviceRepo) FindSingleUnclaimedByNamePlatform(ctx context.Context, userID, name, platform string) (domain.Device, bool, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, user_id, name, platform, client_key, created_at
		FROM devices
		WHERE user_id = ? AND name = ? AND platform = ? AND client_key = ''
		ORDER BY created_at DESC
		LIMIT 2
	`, userID, name, platform)
	if err != nil {
		return domain.Device{}, false, err
	}
	defer rows.Close()

	devices := make([]domain.Device, 0, 2)
	for rows.Next() {
		var device domain.Device
		if err := rows.Scan(&device.ID, &device.UserID, &device.Name, &device.Platform, &device.ClientKey, &device.CreatedAt); err != nil {
			return domain.Device{}, false, err
		}
		devices = append(devices, device)
	}
	if err := rows.Err(); err != nil {
		return domain.Device{}, false, err
	}
	if len(devices) != 1 {
		return domain.Device{}, false, nil
	}
	return devices[0], true, nil
}

func (r *DeviceRepo) UpdateClientKeyAndProfile(ctx context.Context, device domain.Device) (domain.Device, error) {
	result, err := r.db.ExecContext(ctx, `
		UPDATE devices
		SET client_key = ?, name = ?, platform = ?
		WHERE user_id = ? AND id = ?
	`, device.ClientKey, device.Name, device.Platform, device.UserID, device.ID)
	if err != nil {
		return domain.Device{}, err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return domain.Device{}, err
	}
	if affected != 1 {
		return domain.Device{}, fmt.Errorf("更新设备失败：设备不存在或无权访问")
	}
	return device, nil
}

func (r *DeviceRepo) ExistsForUser(ctx context.Context, userID, deviceID string) (bool, error) {
	var id string
	err := r.db.QueryRowContext(ctx, `
		SELECT id
		FROM devices
		WHERE user_id = ? AND id = ?
	`, userID, deviceID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
