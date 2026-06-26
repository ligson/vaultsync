package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
		return domain.UploadSession{}, errors.New("device id is required")
	}
	if strings.TrimSpace(syncRootID) == "" {
		return domain.UploadSession{}, errors.New("sync root id is required")
	}
	if strings.TrimSpace(objectID) == "" {
		return domain.UploadSession{}, errors.New("object id is required")
	}
	if strings.TrimSpace(versionID) == "" {
		return domain.UploadSession{}, errors.New("version id is required")
	}
	if strings.TrimSpace(encryptedName) == "" {
		return domain.UploadSession{}, errors.New("encrypted name is required")
	}
	if totalSize < 0 || chunkSize <= 0 {
		return domain.UploadSession{}, errors.New("invalid upload size")
	}
	deviceExists, err := s.deviceRepo.ExistsForUser(ctx, userID, strings.TrimSpace(deviceID))
	if err != nil {
		return domain.UploadSession{}, err
	}
	if !deviceExists {
		return domain.UploadSession{}, errors.New("device does not belong to user")
	}
	root, err := s.syncRootRepo.GetForUser(ctx, userID, strings.TrimSpace(syncRootID))
	if err != nil {
		return domain.UploadSession{}, errors.New("sync root does not belong to user")
	}
	if root.DeviceID != strings.TrimSpace(deviceID) {
		return domain.UploadSession{}, errors.New("sync root does not belong to device")
	}

	mergedMetadata, err := mergeUploadMetadata(metadataJSON, encryptedName)
	if err != nil {
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

func (s *UploadService) AppendChunk(ctx context.Context, userID, sessionID string, chunk io.Reader) error {
	session, err := s.repo.GetUploadSession(ctx, userID, sessionID)
	if err != nil {
		return err
	}
	if session.Status != "pending" {
		return errors.New("upload session is not pending")
	}
	payload, err := io.ReadAll(chunk)
	if err != nil {
		return err
	}
	if session.ReceivedSize+int64(len(payload)) > session.TotalSize {
		return errors.New("upload exceeds total size")
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
		return domain.FileVersion{}, err
	}
	if session.Status != "pending" {
		return domain.FileVersion{}, errors.New("upload session is not pending")
	}
	if session.ReceivedSize != session.TotalSize {
		return domain.FileVersion{}, errors.New("upload is incomplete")
	}
	contentPath, hashValue, size, err := s.storage.FinalizeUpload(userID, sessionID, session.VersionID)
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
			return "", err
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
		return "", err
	}
	value, _ := payload["encrypted_name"].(string)
	if strings.TrimSpace(value) == "" {
		return "", errors.New("encrypted name is required")
	}
	return value, nil
}
