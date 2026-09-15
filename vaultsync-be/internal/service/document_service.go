package service

import (
	"context"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

const defaultDocumentCandidateLimit = 200

type DocumentOverview struct {
	Devices []domain.Device `json:"devices"`
}

type DocumentService struct {
	repo *store.DocumentRepo
	now  func() time.Time
}

func NewDocumentService(repo *store.DocumentRepo) *DocumentService {
	return &DocumentService{repo: repo, now: func() time.Time { return time.Now().UTC() }}
}

func (s *DocumentService) Overview(ctx context.Context, userID string) (DocumentOverview, error) {
	devices, err := s.repo.ListDevices(ctx, userID)
	if err != nil {
		return DocumentOverview{}, err
	}
	return DocumentOverview{Devices: devices}, nil
}

func (s *DocumentService) Items(ctx context.Context, userID string, limit, cursor int, documentType, deviceID, sortBy, order string) (domain.DocumentAssetPage, error) {
	if cursor < 0 {
		return domain.DocumentAssetPage{}, InvalidRequest("分页游标不能小于 0")
	}
	if limit <= 0 {
		limit = 60
	}
	if limit > 200 {
		return domain.DocumentAssetPage{}, InvalidRequest("单页最多返回 200 项")
	}
	documentType, err := validateDocumentType(documentType, true)
	if err != nil {
		return domain.DocumentAssetPage{}, err
	}
	sortBy = strings.TrimSpace(sortBy)
	if sortBy == "" || sortBy == "name" {
		sortBy = "time"
	}
	if sortBy != "time" && sortBy != "type" && sortBy != "size" {
		return domain.DocumentAssetPage{}, InvalidRequest("排序字段不正确")
	}
	order = strings.TrimSpace(order)
	if order == "" {
		order = "desc"
	}
	if order != "asc" && order != "desc" {
		return domain.DocumentAssetPage{}, InvalidRequest("排序方向不正确")
	}
	items, err := s.repo.ListItems(ctx, userID, documentType,
		strings.TrimSpace(deviceID), sortBy, order, cursor, limit+1)
	if err != nil {
		return domain.DocumentAssetPage{}, err
	}
	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	nextCursor := cursor
	if hasMore {
		nextCursor += len(items)
	}
	return domain.DocumentAssetPage{Items: items, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (s *DocumentService) Candidates(ctx context.Context, userID string, cursorValue int64, limit int) (domain.RemoteBackupObjectPage, error) {
	if cursorValue < 0 {
		return domain.RemoteBackupObjectPage{}, InvalidRequest("游标参数不能小于 0")
	}
	if limit <= 0 {
		limit = defaultDocumentCandidateLimit
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

func (s *DocumentService) Backfill(ctx context.Context, userID string, inputs []domain.DocumentBackfillInput, ignoredVersionIDs []string) (map[string]int, error) {
	if len(inputs)+len(ignoredVersionIDs) > 2000 {
		return nil, InvalidRequest("单次最多检查 2000 个文件版本")
	}
	items := make([]domain.DocumentAsset, 0, len(inputs))
	for _, input := range inputs {
		documentType, err := validateDocumentType(input.DocumentType, false)
		if err != nil {
			return nil, err
		}
		documentFormat := strings.ToLower(strings.TrimSpace(input.DocumentFormat))
		if !validDocumentFormat(documentType, documentFormat) {
			return nil, InvalidRequest("文档格式不正确")
		}
		updatedAt, err := time.Parse(time.RFC3339, strings.TrimSpace(input.UpdatedAt))
		if err != nil {
			return nil, InvalidRequest("文档更新时间格式不正确")
		}
		exists, err := s.repo.VersionExists(ctx, userID,
			strings.TrimSpace(input.SyncRootID), strings.TrimSpace(input.ObjectID),
			strings.TrimSpace(input.VersionID))
		if err != nil {
			return nil, err
		}
		if !exists {
			return nil, InvalidRequest("文档索引对应的文件版本不存在")
		}
		items = append(items, domain.DocumentAsset{
			ID: newID(), SyncRootID: strings.TrimSpace(input.SyncRootID),
			ObjectID:  strings.TrimSpace(input.ObjectID),
			VersionID: strings.TrimSpace(input.VersionID), DocumentType: documentType,
			DocumentFormat: documentFormat, UpdatedAt: updatedAt.UTC().Format(time.RFC3339),
		})
	}
	for _, versionID := range ignoredVersionIDs {
		if strings.TrimSpace(versionID) == "" {
			return nil, InvalidRequest("已检查文件版本 ID 不能为空")
		}
		belongs, err := s.repo.VersionBelongsToUser(ctx, userID, strings.TrimSpace(versionID))
		if err != nil {
			return nil, err
		}
		if !belongs {
			return nil, InvalidRequest("已检查文件版本不存在")
		}
	}
	indexed, marked, err := s.repo.InsertBackfill(ctx, userID, items,
		ignoredVersionIDs, s.now().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	return map[string]int{"indexed_count": indexed, "marked_count": marked}, nil
}

func validateDocumentType(value string, allowEmpty bool) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" && allowEmpty {
		return "", nil
	}
	if value != "office" && value != "pdf" && value != "text" && value != "ebook" {
		return "", InvalidRequest("文档类型只支持 office、pdf、text 或 ebook")
	}
	return value, nil
}

func validDocumentFormat(documentType, format string) bool {
	formats := map[string]map[string]bool{
		"office": {
			"doc": true, "docx": true, "docm": true, "dot": true, "dotx": true, "dotm": true,
			"xls": true, "xlsx": true, "xlsm": true, "xlt": true, "xltx": true, "xltm": true,
			"ppt": true, "pptx": true, "pptm": true, "pot": true, "potx": true, "potm": true,
			"odt": true, "ods": true, "odp": true, "pages": true, "numbers": true, "key": true,
		},
		"pdf":   {"pdf": true},
		"text":  {"txt": true, "md": true, "markdown": true, "rtf": true, "csv": true, "tsv": true, "json": true, "xml": true, "yaml": true, "yml": true, "log": true},
		"ebook": {"epub": true, "mobi": true, "azw": true, "azw3": true, "fb2": true, "djvu": true, "cbz": true, "cbr": true},
	}
	return formats[documentType][format]
}
