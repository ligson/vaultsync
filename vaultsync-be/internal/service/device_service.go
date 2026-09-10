package service

import (
	"context"
	"errors"
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

func (s *DeviceService) Register(ctx context.Context, userID, name, platform, clientKey, currentDeviceID string) (domain.Device, error) {
	name = strings.TrimSpace(name)
	platform = strings.TrimSpace(platform)
	clientKey = strings.TrimSpace(clientKey)
	currentDeviceID = strings.TrimSpace(currentDeviceID)
	if name == "" {
		return domain.Device{}, InvalidRequest("设备名称不能为空")
	}
	if platform == "" {
		return domain.Device{}, InvalidRequest("设备平台不能为空")
	}
	if len(clientKey) > 200 {
		return domain.Device{}, InvalidRequest("设备识别信息过长")
	}
	if len(currentDeviceID) > 100 {
		return domain.Device{}, InvalidRequest("当前设备 ID 过长")
	}
	if clientKey == "" {
		if device, found, err := s.repo.FindLatestUnclaimedByNamePlatform(ctx, userID, name, platform); err != nil {
			return domain.Device{}, err
		} else if found {
			return device, nil
		}
	}

	if clientKey != "" {
		if device, found, err := s.repo.FindByClientKey(ctx, userID, clientKey); err != nil {
			return domain.Device{}, err
		} else if found {
			device.Name = name
			device.Platform = platform
			return s.repo.UpdateClientKeyAndProfile(ctx, device)
		}
		if strings.HasPrefix(clientKey, "vaultsync-device:v2:android:") && currentDeviceID != "" {
			if device, found, err := s.reconcileAndroidDevice(ctx, userID, currentDeviceID, name, platform, clientKey); err != nil {
				return domain.Device{}, err
			} else if found {
				return device, nil
			}
		}
		if device, found, err := s.repo.FindSingleUnclaimedByNamePlatform(ctx, userID, name, platform); err != nil {
			return domain.Device{}, err
		} else if found {
			device.Name = name
			device.Platform = platform
			device.ClientKey = clientKey
			return s.repo.UpdateClientKeyAndProfile(ctx, device)
		}
		if device, found, err := s.repo.FindSingleUnclaimedWithSyncRoots(ctx, userID, platform); err != nil {
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

func (s *DeviceService) reconcileAndroidDevice(ctx context.Context, userID, currentDeviceID, name, platform, clientKey string) (domain.Device, bool, error) {
	current, found, err := s.repo.GetForUser(ctx, userID, currentDeviceID)
	if err != nil || !found {
		return domain.Device{}, false, err
	}
	if current.Name != name || current.Platform != platform {
		return domain.Device{}, false, nil
	}
	hasData, err := s.repo.HasAssociatedData(ctx, userID, current.ID)
	if err != nil {
		return domain.Device{}, false, err
	}
	if !hasData {
		canonical, unique, err := s.repo.FindUniqueDataBearingByNamePlatform(ctx, userID, name, platform, current.ID)
		if err != nil {
			return domain.Device{}, false, err
		}
		if unique {
			canonical.ClientKey = clientKey
			canonical.Name = name
			canonical.Platform = platform
			updated, err := s.repo.UpdateClientKeyAndProfile(ctx, canonical)
			return updated, err == nil, err
		}
	}
	current.ClientKey = clientKey
	current.Name = name
	current.Platform = platform
	updated, err := s.repo.UpdateClientKeyAndProfile(ctx, current)
	return updated, err == nil, err
}

func (s *DeviceService) Remove(ctx context.Context, userID, deviceID, currentDeviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	currentDeviceID = strings.TrimSpace(currentDeviceID)
	if deviceID == "" {
		return InvalidRequest("设备 ID 不能为空")
	}
	if currentDeviceID == "" {
		return InvalidRequest("无法确认当前设备，请重新登录后再试")
	}
	if deviceID == currentDeviceID {
		return InvalidRequest("不能移除当前设备")
	}
	if err := s.repo.RemoveUnused(ctx, userID, deviceID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return NotFound("设备不存在或无权访问")
		}
		if errors.Is(err, store.ErrDeviceInUse) {
			return InvalidRequest("该设备仍有关联同步数据，不能移除")
		}
		return err
	}
	return nil
}
