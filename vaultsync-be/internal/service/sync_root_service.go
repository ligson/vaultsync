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
	objectRepo *store.ObjectRepo
	now        func() time.Time
}

func NewSyncRootService(repo *store.SyncRootRepo, deviceRepo *store.DeviceRepo, objectRepo *store.ObjectRepo) *SyncRootService {
	return &SyncRootService{
		repo:       repo,
		deviceRepo: deviceRepo,
		objectRepo: objectRepo,
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

func (s *SyncRootService) ListRemoteBackupObjects(ctx context.Context, userID, syncRootID string, cursorValue int64, limit int) (domain.RemoteBackupObjectPage, error) {
	if syncRootID == "" {
		return domain.RemoteBackupObjectPage{}, InvalidRequest("sync root id is required")
	}
	limit, err := normalizeRemoteBackupObjectLimit(limit)
	if err != nil {
		return domain.RemoteBackupObjectPage{}, err
	}
	if _, err := s.repo.GetForUser(ctx, userID, syncRootID); err != nil {
		if err == store.ErrNotFound {
			return domain.RemoteBackupObjectPage{}, NotFound("同步目录不存在或无权访问")
		}
		return domain.RemoteBackupObjectPage{}, err
	}
	items, err := s.objectRepo.ListRemoteBackupObjects(ctx, userID, syncRootID, cursorValue, limit+1)
	if err != nil {
		return domain.RemoteBackupObjectPage{}, err
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	nextCursor := cursorValue
	if len(items) > 0 {
		nextCursor = items[len(items)-1].CursorValue
	}
	return domain.RemoteBackupObjectPage{
		Items:      items,
		NextCursor: nextCursor,
		HasMore:    hasMore,
	}, nil
}

func normalizeRemoteBackupObjectLimit(limit int) (int, error) {
	if limit < 0 {
		return 0, InvalidRequest("limit must be positive")
	}
	if limit == 0 {
		return 100, nil
	}
	if limit > 500 {
		return 500, nil
	}
	return limit, nil
}
