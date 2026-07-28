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
		return domain.Device{}, InvalidRequest("设备名称不能为空")
	}
	if platform == "" {
		return domain.Device{}, InvalidRequest("设备平台不能为空")
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
