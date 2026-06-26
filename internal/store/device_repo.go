package store

import (
	"context"
	"database/sql"
	"errors"

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
		INSERT INTO devices (id, user_id, name, platform, created_at)
		VALUES (?, ?, ?, ?, ?)
	`, device.ID, device.UserID, device.Name, device.Platform, device.CreatedAt)
	if err != nil {
		return domain.Device{}, err
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
