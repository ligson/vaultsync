package service

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/storage"
	"github.com/ligson/vaultsync/internal/store"
)

type UploadService struct {
	repo         *store.ObjectRepo
	deviceRepo   *store.DeviceRepo
	syncRootRepo *store.SyncRootRepo
	storage      *storage.FSStorage
	now          func() time.Time
}

func NewUploadService(repo *store.ObjectRepo, deviceRepo *store.DeviceRepo, syncRootRepo *store.SyncRootRepo, storage *storage.FSStorage) *UploadService {
	return &UploadService{
		repo:         repo,
		deviceRepo:   deviceRepo,
		syncRootRepo: syncRootRepo,
		storage:      storage,
		now:          func() time.Time { return time.Now().UTC() },
	}
}

func (s *UploadService) CreateSession(ctx context.Context, userID, deviceID, syncRootID, objectID, versionID, encryptedName, metadataJSON string, totalSize, chunkSize int64) (domain.UploadSession, error) {
	if strings.TrimSpace(deviceID) == "" {
		return domain.UploadSession{}, InvalidRequest("设备 ID 不能为空")
	}
	if strings.TrimSpace(syncRootID) == "" {
		return domain.UploadSession{}, InvalidRequest("同步目录 ID 不能为空")
	}
	if strings.TrimSpace(objectID) == "" {
		return domain.UploadSession{}, InvalidRequest("文件对象 ID 不能为空")
	}
	if strings.TrimSpace(versionID) == "" {
		return domain.UploadSession{}, InvalidRequest("文件版本 ID 不能为空")
	}
	if strings.TrimSpace(encryptedName) == "" {
		return domain.UploadSession{}, InvalidRequest("加密文件名不能为空")
	}
	if totalSize < 0 || chunkSize <= 0 {
		return domain.UploadSession{}, InvalidRequest("上传文件大小参数不正确")
	}
	deviceExists, err := s.deviceRepo.ExistsForUser(ctx, userID, strings.TrimSpace(deviceID))
	if err != nil {
		return domain.UploadSession{}, err
	}
	if !deviceExists {
		return domain.UploadSession{}, InvalidRequest("设备不属于当前用户")
	}
	root, err := s.syncRootRepo.GetForUser(ctx, userID, strings.TrimSpace(syncRootID))
	if err != nil {
		return domain.UploadSession{}, InvalidRequest("同步目录不存在或无权访问")
	}
	if root.DeviceID != strings.TrimSpace(deviceID) {
		return domain.UploadSession{}, InvalidRequest("同步目录不属于当前设备")
	}

	mergedMetadata, err := mergeUploadMetadata(metadataJSON, encryptedName)
	if err != nil {
		return domain.UploadSession{}, err
	}
	if version, err := s.repo.GetFileVersion(ctx, userID, strings.TrimSpace(versionID)); err == nil {
		return completedUploadSession(
			userID,
			strings.TrimSpace(deviceID),
			strings.TrimSpace(syncRootID),
			strings.TrimSpace(objectID),
			strings.TrimSpace(versionID),
			chunkSize,
			version,
			mergedMetadata,
		), nil
	} else if err != store.ErrNotFound {
		return domain.UploadSession{}, err
	}

	session := domain.UploadSession{
		ID:            newID(),
		UserID:        userID,
		DeviceID:      deviceID,
		SyncRootID:    syncRootID,
		ObjectID:      objectID,
		VersionID:     versionID,
		EncryptedName: encryptedName,
		TotalSize:     totalSize,
		ChunkSize:     chunkSize,
		ReceivedSize:  0,
		Status:        "pending",
		MetadataJSON:  mergedMetadata,
		CreatedAt:     s.now().Format(time.RFC3339),
	}
	return s.repo.CreateUploadSession(ctx, session)
}

func (s *UploadService) GetSession(ctx context.Context, userID, sessionID string) (domain.UploadSession, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return domain.UploadSession{}, InvalidRequest("上传会话 ID 不能为空")
	}
	session, err := s.repo.GetUploadSession(ctx, userID, sessionID)
	if err != nil {
		if err == store.ErrNotFound {
			return domain.UploadSession{}, NotFound("上传任务不存在或无权访问")
		}
		return domain.UploadSession{}, err
	}
	if session.Status == "pending" {
		if version, err := s.repo.GetFileVersion(ctx, userID, session.VersionID); err == nil {
			return completedUploadSession(
				userID,
				session.DeviceID,
				session.SyncRootID,
				session.ObjectID,
				session.VersionID,
				session.ChunkSize,
				version,
				session.MetadataJSON,
			), nil
		} else if err != store.ErrNotFound {
			return domain.UploadSession{}, err
		}
	}
	return session, nil
}

func (s *UploadService) AppendChunk(ctx context.Context, userID, sessionID string, chunk io.Reader) error {
	session, err := s.repo.GetUploadSession(ctx, userID, sessionID)
	if err != nil {
		if err == store.ErrNotFound {
			return NotFound("上传任务不存在或无权访问")
		}
		return err
	}
	if session.Status != "pending" {
		return InvalidRequest("上传任务状态不允许继续上传")
	}
	payload, err := io.ReadAll(chunk)
	if err != nil {
		return err
	}
	if session.ReceivedSize+int64(len(payload)) > session.TotalSize {
		return InvalidRequest("上传内容超过声明的文件大小")
	}
	written, err := s.storage.AppendChunk(userID, sessionID, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	return s.repo.AddReceivedBytes(ctx, userID, sessionID, written)
}

func (s *UploadService) Complete(ctx context.Context, userID, sessionID string) (domain.FileVersion, error) {
	session, err := s.repo.GetUploadSession(ctx, userID, sessionID)
	if err != nil {
		if err == store.ErrNotFound {
			return domain.FileVersion{}, NotFound("上传任务不存在或无权访问")
		}
		return domain.FileVersion{}, err
	}
	if session.Status != "pending" {
		return domain.FileVersion{}, InvalidRequest("上传任务状态不允许完成")
	}
	if version, err := s.repo.GetFileVersion(ctx, userID, session.VersionID); err == nil {
		return version, nil
	} else if err != store.ErrNotFound {
		return domain.FileVersion{}, err
	}
	if session.ReceivedSize != session.TotalSize {
		return domain.FileVersion{}, InvalidRequest("文件还没有上传完整")
	}
	root, err := s.syncRootRepo.GetForUser(ctx, userID, session.SyncRootID)
	if err != nil {
		return domain.FileVersion{}, InvalidRequest("同步目录不存在或无权访问")
	}
	contentPath, hashValue, size, err := s.storage.FinalizeUpload(userID, sessionID, session.VersionID, root.EncryptionEnabled, session.TotalSize)
	if err != nil {
		return domain.FileVersion{}, err
	}
	encryptedName, err := extractEncryptedName(session.MetadataJSON)
	if err != nil {
		return domain.FileVersion{}, err
	}
	version := domain.FileVersion{
		ID:            session.VersionID,
		UserID:        userID,
		SyncRootID:    session.SyncRootID,
		ObjectID:      session.ObjectID,
		EncryptedName: encryptedName,
		ContentPath:   contentPath,
		ContentHash:   hashValue,
		SizeBytes:     size,
		MetadataJSON:  session.MetadataJSON,
		CreatedAt:     s.now().Format(time.RFC3339),
	}
	return s.repo.CompleteUpload(ctx, sessionID, version)
}

func mergeUploadMetadata(metadataJSON, encryptedName string) (string, error) {
	payload := map[string]any{}
	if strings.TrimSpace(metadataJSON) != "" {
		if err := json.Unmarshal([]byte(metadataJSON), &payload); err != nil {
			return "", InvalidRequest("文件元数据格式不正确")
		}
	}
	payload["encrypted_name"] = encryptedName
	merged, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return string(merged), nil
}

func extractEncryptedName(metadataJSON string) (string, error) {
	var payload map[string]any
	if err := json.Unmarshal([]byte(metadataJSON), &payload); err != nil {
		return "", InvalidRequest("文件元数据格式不正确")
	}
	value, _ := payload["encrypted_name"].(string)
	if strings.TrimSpace(value) == "" {
		return "", InvalidRequest("加密文件名不能为空")
	}
	return value, nil
}

func completedUploadSession(userID, deviceID, syncRootID, objectID, versionID string, chunkSize int64, version domain.FileVersion, metadataJSON string) domain.UploadSession {
	return domain.UploadSession{
		ID:            "completed:" + versionID,
		UserID:        userID,
		DeviceID:      deviceID,
		SyncRootID:    syncRootID,
		ObjectID:      objectID,
		VersionID:     versionID,
		EncryptedName: version.EncryptedName,
		TotalSize:     version.SizeBytes,
		ChunkSize:     chunkSize,
		ReceivedSize:  version.SizeBytes,
		Status:        "completed",
		MetadataJSON:  metadataJSON,
		CreatedAt:     version.CreatedAt,
	}
}
