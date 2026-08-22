package service

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/storage"
	"github.com/ligson/vaultsync/internal/store"
)

// The client limits the original image to 5 MiB. XChaCha ciphertext is wrapped
// in a JSON/base64 envelope, so the server allowance includes that overhead.
const maxAvatarBytes int64 = 8 * 1024 * 1024

type AvatarService struct {
	repo    *store.AvatarRepo
	storage *storage.FSStorage
	now     func() time.Time
}

func NewAvatarService(repo *store.AvatarRepo, storage *storage.FSStorage) *AvatarService {
	return &AvatarService{
		repo:    repo,
		storage: storage,
		now:     func() time.Time { return time.Now().UTC() },
	}
}

func (s *AvatarService) Save(ctx context.Context, userID string, content io.Reader) (domain.UserAvatar, error) {
	contentPath, hashValue, size, err := s.storage.StoreAvatar(userID, content, maxAvatarBytes)
	if errors.Is(err, storage.ErrMaxSizeExceeded) {
		return domain.UserAvatar{}, InvalidRequest("头像文件不能超过 5 MB")
	}
	if err != nil {
		return domain.UserAvatar{}, err
	}
	avatar := domain.UserAvatar{
		UserID:      userID,
		ContentHash: hashValue,
		SizeBytes:   size,
		UpdatedAt:   s.now().Format(time.RFC3339Nano),
	}
	if err := s.repo.Upsert(ctx, avatar, contentPath); err != nil {
		return domain.UserAvatar{}, err
	}
	return avatar, nil
}

func (s *AvatarService) Open(ctx context.Context, userID string) (io.ReadCloser, domain.UserAvatar, error) {
	avatar, err := s.repo.Find(ctx, userID)
	if err == store.ErrNotFound {
		return nil, domain.UserAvatar{}, NotFound("头像不存在")
	}
	if err != nil {
		return nil, domain.UserAvatar{}, err
	}
	file, err := s.storage.OpenAvatar(userID)
	if err != nil {
		return nil, domain.UserAvatar{}, err
	}
	return file, avatar, nil
}
