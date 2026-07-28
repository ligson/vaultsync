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

func (s *SyncRootService) Create(ctx context.Context, userID, deviceID, encryptedPath, cleanupPolicy, archivePath string, encryptionEnabled bool) (domain.SyncRoot, error) {
	deviceID = strings.TrimSpace(deviceID)
	encryptedPath = strings.TrimSpace(encryptedPath)
	cleanupPolicy = strings.TrimSpace(cleanupPolicy)
	if deviceID == "" {
		return domain.SyncRoot{}, InvalidRequest("设备 ID 不能为空")
	}
	if encryptedPath == "" {
		return domain.SyncRoot{}, InvalidRequest("同步目录路径不能为空")
	}
	if cleanupPolicy == "" {
		return domain.SyncRoot{}, InvalidRequest("本地清理策略不能为空")
	}
	deviceExists, err := s.deviceRepo.ExistsForUser(ctx, userID, deviceID)
	if err != nil {
		return domain.SyncRoot{}, err
	}
	if !deviceExists {
		return domain.SyncRoot{}, InvalidRequest("设备不属于当前用户")
	}

	root := domain.SyncRoot{
		ID:                newID(),
		UserID:            userID,
		DeviceID:          deviceID,
		EncryptedPath:     encryptedPath,
		EncryptionEnabled: encryptionEnabled,
		CleanupPolicy:     cleanupPolicy,
		ArchivePath:       archivePath,
		CreatedAt:         s.now().Format(time.RFC3339),
	}
	return s.repo.Create(ctx, root)
}

func (s *SyncRootService) ListByUser(ctx context.Context, userID string) ([]domain.SyncRoot, error) {
	return s.repo.ListByUser(ctx, userID)
}

func (s *SyncRootService) UpdateCleanupPolicy(ctx context.Context, userID, syncRootID, cleanupPolicy, archivePath string) (domain.SyncRoot, error) {
	syncRootID = strings.TrimSpace(syncRootID)
	cleanupPolicy = strings.TrimSpace(cleanupPolicy)
	if syncRootID == "" {
		return domain.SyncRoot{}, InvalidRequest("同步目录 ID 不能为空")
	}
	if cleanupPolicy == "" {
		return domain.SyncRoot{}, InvalidRequest("本地清理策略不能为空")
	}
	root, err := s.repo.UpdateCleanupPolicy(ctx, userID, syncRootID, cleanupPolicy, archivePath)
	if err != nil {
		if err == store.ErrNotFound {
			return domain.SyncRoot{}, NotFound("同步目录不存在或无权访问")
		}
		return domain.SyncRoot{}, err
	}
	return root, nil
}

func (s *SyncRootService) Delete(ctx context.Context, userID, syncRootID string, deleteRemote bool) (map[string]any, error) {
	syncRootID = strings.TrimSpace(syncRootID)
	if syncRootID == "" {
		return nil, InvalidRequest("同步目录 ID 不能为空")
	}
	root, err := s.repo.GetForUser(ctx, userID, syncRootID)
	if err != nil {
		if err == store.ErrNotFound {
			return nil, NotFound("同步目录不存在或无权访问")
		}
		return nil, err
	}
	deletedObjects, err := s.repo.DeleteForUser(ctx, userID, root.ID, root.DeviceID, deleteRemote, s.now().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"id":                     root.ID,
		"delete_remote":          deleteRemote,
		"remote_tombstone_count": deletedObjects,
	}, nil
}

func (s *SyncRootService) ListRemoteBackupObjects(ctx context.Context, userID, syncRootID string, cursorValue int64, limit int) (domain.RemoteBackupObjectPage, error) {
	if syncRootID == "" {
		return domain.RemoteBackupObjectPage{}, InvalidRequest("同步目录 ID 不能为空")
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
		return 0, InvalidRequest("分页大小不能小于 0")
	}
	if limit == 0 {
		return 100, nil
	}
	if limit > 500 {
		return 500, nil
	}
	return limit, nil
}
