package service

import (
	"context"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

type DeviceService struct {
	repo *store.DeviceRepo
	now  func() time.Time
}

func NewDeviceService(repo *store.DeviceRepo) *DeviceService {
	return &DeviceService{
		repo: repo,
		now:  func() time.Time { return time.Now().UTC() },
	}
}

func (s *DeviceService) Register(ctx context.Context, userID, name, platform string) (domain.Device, error) {
	name = strings.TrimSpace(name)
	platform = strings.TrimSpace(platform)
	if name == "" {
		return domain.Device{}, InvalidRequest("device name is required")
	}
	if platform == "" {
		return domain.Device{}, InvalidRequest("device platform is required")
	}

	device := domain.Device{
		ID:        newID(),
		UserID:    userID,
		Name:      name,
		Platform:  platform,
		CreatedAt: s.now().Format(time.RFC3339),
	}
	return s.repo.Create(ctx, device)
}
