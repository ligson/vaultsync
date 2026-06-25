package store

import (
	"context"
	"database/sql"

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
