package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

type SyncRootService struct {
	repo *store.SyncRootRepo
	now  func() time.Time
}

func NewSyncRootService(repo *store.SyncRootRepo) *SyncRootService {
	return &SyncRootService{
		repo: repo,
		now:  func() time.Time { return time.Now().UTC() },
	}
}

func (s *SyncRootService) Create(ctx context.Context, userID, deviceID, encryptedPath, cleanupPolicy, archivePath string) (domain.SyncRoot, error) {
	deviceID = strings.TrimSpace(deviceID)
	encryptedPath = strings.TrimSpace(encryptedPath)
	cleanupPolicy = strings.TrimSpace(cleanupPolicy)
	if deviceID == "" {
		return domain.SyncRoot{}, errors.New("device id is required")
	}
	if encryptedPath == "" {
		return domain.SyncRoot{}, errors.New("encrypted path is required")
	}
	if cleanupPolicy == "" {
		return domain.SyncRoot{}, errors.New("cleanup policy is required")
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
