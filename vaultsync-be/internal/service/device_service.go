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

func (s *DeviceService) Register(ctx context.Context, userID, name, platform, clientKey string) (domain.Device, error) {
	name = strings.TrimSpace(name)
	platform = strings.TrimSpace(platform)
	clientKey = strings.TrimSpace(clientKey)
	if name == "" {
		return domain.Device{}, InvalidRequest("设备名称不能为空")
	}
	if platform == "" {
		return domain.Device{}, InvalidRequest("设备平台不能为空")
	}
	if len(clientKey) > 200 {
		return domain.Device{}, InvalidRequest("设备识别信息过长")
	}

	if clientKey != "" {
		if device, found, err := s.repo.FindByClientKey(ctx, userID, clientKey); err != nil {
			return domain.Device{}, err
		} else if found {
			device.Name = name
			device.Platform = platform
			return s.repo.UpdateClientKeyAndProfile(ctx, device)
		}
		if device, found, err := s.repo.FindSingleUnclaimedByNamePlatform(ctx, userID, name, platform); err != nil {
			return domain.Device{}, err
		} else if found {
			device.Name = name
			device.Platform = platform
			device.ClientKey = clientKey
			return s.repo.UpdateClientKeyAndProfile(ctx, device)
		}
	}

	device := domain.Device{
		ID:        newID(),
		UserID:    userID,
		Name:      name,
		Platform:  platform,
		ClientKey: clientKey,
		CreatedAt: s.now().Format(time.RFC3339),
	}
	return s.repo.Create(ctx, device)
}
