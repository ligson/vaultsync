package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/storage"
	"github.com/ligson/vaultsync/internal/store"
)

const maxMediaThumbnailSize = 2 << 20

type MediaOverview struct {
	Items   []domain.MediaMonth `json:"items"`
	Devices []domain.Device     `json:"devices"`
}

const defaultMediaCandidateLimit = 200

type MediaService struct {
	repo         *store.MediaRepo
	syncRootRepo *store.SyncRootRepo
	storage      *storage.FSStorage
	now          func() time.Time
}

func NewMediaService(repo *store.MediaRepo, syncRootRepo *store.SyncRootRepo, storage *storage.FSStorage) *MediaService {
	return &MediaService{repo: repo, syncRootRepo: syncRootRepo, storage: storage, now: func() time.Time { return time.Now().UTC() }}
}

func (s *MediaService) Months(ctx context.Context, userID, mediaType, deviceID string) (MediaOverview, error) {
	mediaType, err := validateMediaTypeFilter(mediaType)
	if err != nil {
		return MediaOverview{}, err
	}
	items, err := s.repo.ListMonths(ctx, userID, mediaType, strings.TrimSpace(deviceID))
	if err != nil {
		return MediaOverview{}, err
	}
	devices, err := s.repo.ListDevices(ctx, userID)
	if err != nil {
		return MediaOverview{}, err
	}
	return MediaOverview{Items: items, Devices: devices}, nil
}

func (s *MediaService) Items(ctx context.Context, userID string, year, month, limit int, mediaType, deviceID, cursor string) (domain.MediaAssetPage, error) {
	if year < 1970 || year > 9999 || month < 1 || month > 12 {
		return domain.MediaAssetPage{}, InvalidRequest("年月参数不正确")
	}
	if limit <= 0 {
		limit = 60
	}
	if limit > 200 {
		return domain.MediaAssetPage{}, InvalidRequest("单页最多返回 200 项")
	}
	mediaType, err := validateMediaTypeFilter(mediaType)
	if err != nil {
		return domain.MediaAssetPage{}, err
	}
	cursorTime, cursorID, err := decodeMediaCursor(cursor)
	if err != nil {
		return domain.MediaAssetPage{}, InvalidRequest("分页游标无效")
	}
	items, err := s.repo.ListItems(ctx, userID, year, month, mediaType,
		strings.TrimSpace(deviceID), cursorTime, cursorID, limit+1)
	if err != nil {
		return domain.MediaAssetPage{}, err
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	nextCursor := ""
	if hasMore && len(items) > 0 {
		nextCursor = encodeMediaCursor(items[len(items)-1])
	}
	return domain.MediaAssetPage{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *MediaService) Candidates(ctx context.Context, userID string, cursorValue int64, limit int) (domain.RemoteBackupObjectPage, error) {
	if cursorValue < 0 {
		return domain.RemoteBackupObjectPage{}, InvalidRequest("游标参数不能小于 0")
	}
	if limit <= 0 {
		limit = defaultMediaCandidateLimit
	}
	if limit > 500 {
		limit = 500
	}
	items, err := s.repo.ListUnindexedCandidates(ctx, userID, cursorValue, limit+1)
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
	return domain.RemoteBackupObjectPage{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *MediaService) PutThumbnail(ctx context.Context, userID, mediaID string, content io.Reader) error {
	mediaID = strings.TrimSpace(mediaID)
	if mediaID == "" {
		return InvalidRequest("媒体 ID 不能为空")
	}
	if _, err := s.repo.GetForUser(ctx, userID, mediaID); err != nil {
		if err == store.ErrNotFound {
			return NotFound("媒体不存在或无权访问")
		}
		return err
	}
	path, size, err := s.storage.StoreMediaThumbnail(userID, mediaID, content, maxMediaThumbnailSize)
	if errors.Is(err, storage.ErrMaxSizeExceeded) {
		return InvalidRequest("缩略图密文不能超过 2 MB")
	}
	if err != nil {
		return err
	}
	return s.repo.SetThumbnail(ctx, userID, mediaID, path, size, s.now().Format(time.RFC3339))
}

func (s *MediaService) Backfill(ctx context.Context, userID string, inputs []domain.MediaBackfillInput) (map[string]int, error) {
	if len(inputs) > 2000 {
		return nil, InvalidRequest("单次最多回填 2000 条媒体索引")
	}
	items := make([]domain.MediaAsset, 0, len(inputs))
	for _, input := range inputs {
		root, err := s.syncRootRepo.GetForUser(ctx, userID, strings.TrimSpace(input.SyncRootID))
		if err != nil || !strings.HasPrefix(root.EncryptedPath, "media-backup:v1:") {
			return nil, InvalidRequest("媒体索引包含无效的相册备份目录")
		}
		validatedJSON, err := validateMediaIndex(root, &input.MediaIndexInput)
		if err != nil {
			return nil, err
		}
		var validated domain.MediaIndexInput
		if err := json.Unmarshal([]byte(validatedJSON), &validated); err != nil {
			return nil, err
		}
		exists, err := s.repo.VersionExists(ctx, userID, root.ID,
			strings.TrimSpace(input.ObjectID), strings.TrimSpace(input.VersionID))
		if err != nil {
			return nil, err
		}
		if !exists {
			return nil, InvalidRequest("媒体索引对应的文件版本不存在")
		}
		items = append(items, domain.MediaAsset{
			ID: newID(), DeviceID: root.DeviceID, SyncRootID: root.ID,
			ObjectID: strings.TrimSpace(input.ObjectID), VersionID: strings.TrimSpace(input.VersionID),
			MediaType: validated.MediaType, CapturedAt: validated.CapturedAt,
			CapturedYear: validated.CapturedYear, CapturedMonth: validated.CapturedMonth,
			Width: validated.Width, Height: validated.Height, DurationMS: validated.DurationMS,
		})
	}
	inserted, err := s.repo.InsertBackfill(ctx, userID, items)
	if err != nil {
		return nil, err
	}
	return map[string]int{"indexed_count": inserted}, nil
}

func (s *MediaService) OpenThumbnail(ctx context.Context, userID, mediaID string) (*os.File, error) {
	item, err := s.repo.GetForUser(ctx, userID, strings.TrimSpace(mediaID))
	if err != nil || !item.HasThumbnail {
		if err == nil || err == store.ErrNotFound {
			return nil, NotFound("缩略图不存在或无权访问")
		}
		return nil, err
	}
	file, err := s.storage.OpenMediaThumbnail(userID, item.ID)
	if errors.Is(err, os.ErrNotExist) {
		return nil, NotFound("缩略图不存在")
	}
	return file, err
}

func validateMediaTypeFilter(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value != "" && value != "image" && value != "video" {
		return "", InvalidRequest("媒体类型只支持 image 或 video")
	}
	return value, nil
}

type mediaCursor struct {
	CapturedAt string `json:"captured_at"`
	ID         string `json:"id"`
}

func encodeMediaCursor(item domain.MediaAsset) string {
	payload, _ := json.Marshal(mediaCursor{CapturedAt: item.CapturedAt, ID: item.ID})
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeMediaCursor(value string) (string, string, error) {
	if strings.TrimSpace(value) == "" {
		return "", "", nil
	}
	payload, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return "", "", err
	}
	var cursor mediaCursor
	if err := json.Unmarshal(payload, &cursor); err != nil {
		return "", "", err
	}
	if cursor.ID == "" {
		return "", "", errors.New("empty cursor id")
	}
	if _, err := time.Parse(time.RFC3339, cursor.CapturedAt); err != nil {
		return "", "", err
	}
	return cursor.CapturedAt, cursor.ID, nil
}
