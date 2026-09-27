package service

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

const defaultDocumentCandidateLimit = 200
const documentBookshelfLimit = 100

type DocumentOverview struct {
	Devices []domain.Device `json:"devices"`
}

type DocumentService struct {
	repo    *store.DocumentRepo
	dataDir string
	now     func() time.Time
}

func NewDocumentService(repo *store.DocumentRepo, dataDir string) *DocumentService {
	return &DocumentService{repo: repo, dataDir: dataDir, now: func() time.Time { return time.Now().UTC() }}
}

func (s *DocumentService) Overview(ctx context.Context, userID string) (DocumentOverview, error) {
	devices, err := s.repo.ListDevices(ctx, userID)
	if err != nil {
		return DocumentOverview{}, err
	}
	return DocumentOverview{Devices: devices}, nil
}

func (s *DocumentService) Bookshelf(ctx context.Context, userID string) ([]domain.DocumentBookshelfItem, error) {
	return s.repo.ListBookshelf(ctx, userID, documentBookshelfLimit)
}

func (s *DocumentService) UpdateBookshelf(ctx context.Context, userID, documentID, sectionID string, offset int64, progress float64) (domain.DocumentBookshelfItem, error) {
	if offset < 0 {
		return domain.DocumentBookshelfItem{}, InvalidRequest("阅读位置不能小于 0")
	}
	if progress < 0 || progress > 1 {
		return domain.DocumentBookshelfItem{}, InvalidRequest("阅读进度必须在 0 到 1 之间")
	}
	items, err := s.repo.ListBookshelf(ctx, userID, documentBookshelfLimit+1)
	if err != nil {
		return domain.DocumentBookshelfItem{}, err
	}
	if len(items) >= documentBookshelfLimit {
		alreadyExists := false
		for _, item := range items {
			if item.DocumentID == documentID {
				alreadyExists = true
				break
			}
		}
		if !alreadyExists {
			return domain.DocumentBookshelfItem{}, InvalidRequest("书架最多保存 100 本书，请先移除一本再加入")
		}
	}
	return s.repo.UpsertBookshelf(ctx, userID, strings.TrimSpace(documentID), strings.TrimSpace(sectionID), offset, progress, s.now().Format(time.RFC3339))
}

func (s *DocumentService) DeleteBookshelf(ctx context.Context, userID, documentID string) error {
	return s.repo.DeleteBookshelf(ctx, userID, strings.TrimSpace(documentID))
}

func (s *DocumentService) BackfillPlain(ctx context.Context, userID string, cursorValue int64, limit int) (map[string]any, error) {
	if cursorValue < 0 {
		return nil, InvalidRequest("游标参数不能小于 0")
	}
	if limit <= 0 {
		limit = 500
	}
	if limit > 5000 {
		limit = 5000
	}
	candidates, err := s.repo.ListPlainUnindexedCandidates(ctx, userID, cursorValue, limit+1)
	if err != nil {
		return nil, err
	}
	hasMore := len(candidates) > limit
	if hasMore {
		candidates = candidates[:limit]
	}
	items := make([]domain.DocumentAsset, 0, len(candidates))
	ignored := make([]string, 0)
	for _, candidate := range candidates {
		var metadata map[string]any
		if err := json.Unmarshal([]byte(candidate.MetadataJSON), &metadata); err != nil || metadata["format"] != "vaultsync-metadata-plain-v1" {
			ignored = append(ignored, candidate.VersionID)
			continue
		}
		name, _ := metadata["name"].(string)
		path, _ := metadata["relative_path"].(string)
		classification := classifyDocumentPath(path)
		if classification == "" {
			classification = classifyDocumentPath(name)
		}
		if classification == "" {
			ignored = append(ignored, candidate.VersionID)
			continue
		}
		parts := strings.SplitN(classification, ":", 2)
		items = append(items, domain.DocumentAsset{
			ID: newID(), SyncRootID: candidate.SyncRootID, ObjectID: candidate.ObjectID,
			VersionID: candidate.VersionID, DocumentType: parts[0], DocumentFormat: parts[1],
			UpdatedAt: candidate.UpdatedAt,
		})
	}
	indexed, marked, err := s.repo.InsertBackfill(ctx, userID, items, ignored, s.now().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	nextCursor := cursorValue
	if len(candidates) > 0 {
		nextCursor = candidates[len(candidates)-1].CursorValue
	}
	return map[string]any{"indexed_count": indexed, "marked_count": marked, "next_cursor": nextCursor, "has_more": hasMore}, nil
}

func (s *DocumentService) Preview(ctx context.Context, userID, documentID string) (domain.DocumentPreview, error) {
	source, err := s.repo.GetPreviewSource(ctx, userID, strings.TrimSpace(documentID))
	if err != nil {
		if err == store.ErrNotFound {
			return domain.DocumentPreview{}, NotFound("文档不存在或无权访问")
		}
		return domain.DocumentPreview{}, err
	}
	if source.EncryptionEnabled {
		return domain.DocumentPreview{}, Forbidden("为保护数据安全，加密文档不能在线预览，请下载后查看")
	}
	if source.SizeBytes > maxPreviewSourceBytes {
		return domain.DocumentPreview{}, InvalidRequest("文档过大，在线预览上限为 64 MB")
	}
	path := source.ContentPath
	if !filepath.IsAbs(path) {
		path = filepath.Join(s.dataDir, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return domain.DocumentPreview{}, err
	}
	defer file.Close()
	return parseDocumentPreview(file, source, path)
}

func (s *DocumentService) PreviewPage(ctx context.Context, userID, documentID, mode, sectionID string, offset int64, limit int) (domain.DocumentPreview, error) {
	source, err := s.repo.GetPreviewSource(ctx, userID, strings.TrimSpace(documentID))
	if err != nil {
		if err == store.ErrNotFound {
			return domain.DocumentPreview{}, NotFound("文档不存在或无权访问")
		}
		return domain.DocumentPreview{}, err
	}
	if source.EncryptionEnabled {
		return domain.DocumentPreview{}, Forbidden("为保护数据安全，加密文档不能在线预览，请下载后查看")
	}
	if source.SizeBytes > maxPreviewSourceBytes {
		return domain.DocumentPreview{}, InvalidRequest("文档过大，在线预览上限为 64 MB")
	}
	if offset < 0 {
		return domain.DocumentPreview{}, InvalidRequest("预览偏移量不能小于 0")
	}
	if limit <= 0 {
		limit = defaultPreviewPageBytes
	}
	if limit > maxPreviewPageBytes {
		limit = maxPreviewPageBytes
	}
	path := source.ContentPath
	if !filepath.IsAbs(path) {
		path = filepath.Join(s.dataDir, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return domain.DocumentPreview{}, err
	}
	defer file.Close()
	if strings.EqualFold(mode, "meta") {
		return parseDocumentPreviewMetadata(file, source)
	}
	return parseDocumentPreviewPage(file, source, sectionID, offset, limit)
}

func (s *DocumentService) OpenPreviewContent(ctx context.Context, userID, documentID string) (*os.File, string, error) {
	source, err := s.repo.GetPreviewSource(ctx, userID, strings.TrimSpace(documentID))
	if err != nil {
		if err == store.ErrNotFound {
			return nil, "", NotFound("文档不存在或无权访问")
		}
		return nil, "", err
	}
	if source.EncryptionEnabled {
		return nil, "", Forbidden("为保护数据安全，加密文档不能在线预览，请下载后查看")
	}
	if source.Format != "pdf" {
		return nil, "", InvalidRequest("此内容接口只用于 PDF 在线预览")
	}
	path := source.ContentPath
	if !filepath.IsAbs(path) {
		path = filepath.Join(s.dataDir, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, "", err
	}
	encrypted, err := isEncryptedPDF(file)
	if err != nil {
		_ = file.Close()
		return nil, "", InvalidRequest("PDF 内容无法读取，请下载原文件查看")
	}
	if encrypted {
		_ = file.Close()
		return nil, "", Forbidden("为保护数据安全，带密码的 PDF 不能在线预览，请下载后查看")
	}
	return file, previewContentType(source.Format), nil
}

const maxPreviewSourceBytes int64 = 64 * 1024 * 1024

func classifyDocumentPath(path string) string {
	name := strings.ToLower(strings.ReplaceAll(path, "\\", "/"))
	name = name[strings.LastIndex(name, "/")+1:]
	dot := strings.LastIndex(name, ".")
	if dot < 0 || dot == len(name)-1 {
		return ""
	}
	format := name[dot+1:]
	groups := map[string]string{
		"doc": "office", "docx": "office", "docm": "office", "dot": "office", "dotx": "office", "dotm": "office",
		"xls": "office", "xlsx": "office", "xlsm": "office", "xlt": "office", "xltx": "office", "xltm": "office",
		"ppt": "office", "pptx": "office", "pptm": "office", "pot": "office", "potx": "office", "potm": "office",
		"odt": "office", "ods": "office", "odp": "office", "pages": "office", "numbers": "office", "key": "office",
		"pdf": "pdf",
		"txt": "text", "md": "text", "markdown": "text", "rtf": "text", "csv": "text", "tsv": "text", "json": "text", "xml": "text", "yaml": "text", "yml": "text", "log": "text",
		"epub": "ebook", "mobi": "ebook", "azw": "ebook", "azw3": "ebook", "fb2": "ebook", "djvu": "ebook", "cbz": "ebook", "cbr": "ebook",
	}
	group := groups[format]
	if group == "" {
		return ""
	}
	return group + ":" + format
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
