package service

import (
	"context"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

type SyncRootService struct {
	repo       *store.SyncRootRepo
	deviceRepo *store.DeviceRepo
	now        func() time.Time
}

func NewSyncRootService(repo *store.SyncRootRepo, deviceRepo *store.DeviceRepo) *SyncRootService {
	return &SyncRootService{
		repo:       repo,
		deviceRepo: deviceRepo,
		now:        func() time.Time { return time.Now().UTC() },
	}
}

func (s *SyncRootService) Create(ctx context.Context, userID, deviceID, encryptedPath, cleanupPolicy, archivePath string) (domain.SyncRoot, error) {
	deviceID = strings.TrimSpace(deviceID)
	encryptedPath = strings.TrimSpace(encryptedPath)
	cleanupPolicy = strings.TrimSpace(cleanupPolicy)
	if deviceID == "" {
		return domain.SyncRoot{}, InvalidRequest("device id is required")
	}
	if encryptedPath == "" {
		return domain.SyncRoot{}, InvalidRequest("encrypted path is required")
	}
	if cleanupPolicy == "" {
		return domain.SyncRoot{}, InvalidRequest("cleanup policy is required")
	}
	deviceExists, err := s.deviceRepo.ExistsForUser(ctx, userID, deviceID)
	if err != nil {
		return domain.SyncRoot{}, err
	}
	if !deviceExists {
		return domain.SyncRoot{}, InvalidRequest("device does not belong to user")
	}

	root := domain.SyncRoot{
		ID:            newID(),
		UserID:        userID,
		DeviceID:      deviceID,
		EncryptedPath: encryptedPath,
		CleanupPolicy: cleanupPolicy,
		ArchivePath:   archivePath,
		CreatedAt:     s.now().Format(time.RFC3339),
	}
	return s.repo.Create(ctx, root)
}

func (s *SyncRootService) ListByUser(ctx context.Context, userID string) ([]domain.SyncRoot, error) {
	return s.repo.ListByUser(ctx, userID)
}
