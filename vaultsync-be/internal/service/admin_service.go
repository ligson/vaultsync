package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

type AdminService struct {
	repo                     *store.AdminRepo
	adminRegistrationEnabled bool
	defaultUserQuotaBytes    int64
	dataDir                  string
	httpAddr                 string
	databasePath             string
}

func NewAdminService(repo *store.AdminRepo, adminRegistrationEnabled bool, defaultUserQuotaBytes int64, dataDir ...string) *AdminService {
	root := ""
	if len(dataDir) > 0 {
		root = dataDir[0]
	}
	return &AdminService{
		repo:                     repo,
		adminRegistrationEnabled: adminRegistrationEnabled,
		defaultUserQuotaBytes:    defaultUserQuotaBytes,
		dataDir:                  root,
	}
}

func (s *AdminService) SetRuntimePaths(httpAddr, databasePath string) {
	s.httpAddr = httpAddr
	s.databasePath = databasePath
}

func (s *AdminService) EnsureAdmin(ctx context.Context, userID string) error {
	role, err := s.repo.UserRole(ctx, userID)
	if err != nil {
		return Forbidden("没有管理员权限")
	}
	if role != "admin" {
		return Forbidden("没有管理员权限")
	}
	return nil
}

func (s *AdminService) Overview(ctx context.Context) (domain.AdminOverview, error) {
	return s.repo.Overview(ctx)
}

func (s *AdminService) Users(ctx context.Context) ([]domain.User, error) {
	return s.repo.Users(ctx)
}

func (s *AdminService) RecordAudit(ctx context.Context, actorUserID, action string, details map[string]any) error {
	action = strings.TrimSpace(action)
	if actorUserID == "" || action == "" {
		return nil
	}
	content, err := json.Marshal(details)
	if err != nil {
		return err
	}
	return s.repo.InsertAuditLog(ctx, domain.AuditLog{
		ID:          newAuditID(),
		UserID:      actorUserID,
		Action:      action,
		DetailsJSON: string(content),
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
	})
}

func newAuditID() string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(bytes[:])
}

func (s *AdminService) AuditLogs(ctx context.Context, limit int) ([]domain.AuditLog, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	return s.repo.AuditLogs(ctx, limit)
}

func (s *AdminService) SystemStatus(ctx context.Context) (domain.AdminSystemStatus, error) {
	userCount, err := s.repo.CountUsers(ctx)
	if err != nil {
		return domain.AdminSystemStatus{}, err
	}
	deviceCount, err := s.repo.CountDevices(ctx)
	if err != nil {
		return domain.AdminSystemStatus{}, err
	}
	downloadDir := filepath.Join(s.dataDir, "downloads")
	downloadBytes, err := dirSize(downloadDir)
	if err != nil {
		return domain.AdminSystemStatus{}, err
	}
	dataBytes, err := dirSize(s.dataDir)
	if err != nil {
		return domain.AdminSystemStatus{}, err
	}
	var databaseBytes int64
	if info, err := os.Stat(s.databasePath); err == nil {
		databaseBytes = info.Size()
	}
	return domain.AdminSystemStatus{
		Status:           "ok",
		HTTPAddr:         s.httpAddr,
		DataDir:          s.dataDir,
		DatabasePath:     s.databasePath,
		DownloadDir:      downloadDir,
		StorageUsedBytes: dataBytes,
		DatabaseBytes:    databaseBytes,
		DownloadBytes:    downloadBytes,
		UserCount:        userCount,
		DeviceCount:      deviceCount,
	}, nil
}

func (s *AdminService) UpdateUser(ctx context.Context, userID, status string, quotaBytes int64) (domain.User, error) {
	status = strings.TrimSpace(status)
	if status != "active" && status != "disabled" {
		return domain.User{}, InvalidRequest("用户状态只能是 active 或 disabled")
	}
	if quotaBytes < 0 {
		return domain.User{}, InvalidRequest("用户限额不能小于 0")
	}
	user, err := s.repo.UpdateUser(ctx, userID, status, quotaBytes)
	if err != nil {
		if err == store.ErrNotFound {
			return domain.User{}, NotFound("用户不存在")
		}
		return domain.User{}, err
	}
	return user, nil
}

func (s *AdminService) Settings(ctx context.Context) (map[string]any, error) {
	values, err := s.repo.Settings(ctx)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"admin_registration_enabled": s.adminRegistrationEnabled,
		"default_user_quota_bytes":   s.defaultUserQuotaBytes,
		"version_retention_count":    intSetting(values, "version_retention_count", 5),
		"max_upload_bytes":           intSetting(values, "max_upload_bytes", 20*1024*1024*1024),
		"default_cleanup_policy":     stringSetting(values, "default_cleanup_policy", "keep"),
	}, nil
}

func (s *AdminService) UpdateSettings(ctx context.Context, values map[string]any) (map[string]any, error) {
	stored := map[string]string{}
	if value, ok := int64FromAny(values["version_retention_count"]); ok {
		if value < 1 {
			return nil, InvalidRequest("版本保留数量不能小于 1")
		}
		stored["version_retention_count"] = strconv.FormatInt(value, 10)
	}
	if value, ok := int64FromAny(values["max_upload_bytes"]); ok {
		if value < 0 {
			return nil, InvalidRequest("上传大小限制不能小于 0")
		}
		stored["max_upload_bytes"] = strconv.FormatInt(value, 10)
	}
	if value, ok := values["default_cleanup_policy"].(string); ok {
		value = strings.TrimSpace(value)
		if value != "keep" && value != "delete" {
			return nil, InvalidRequest("默认清理策略只能是 keep 或 delete")
		}
		stored["default_cleanup_policy"] = value
	}
	if err := s.repo.UpsertSettings(ctx, stored); err != nil {
		return nil, err
	}
	return s.Settings(ctx)
}

func (s *AdminService) Downloads(ctx context.Context) ([]domain.DownloadRelease, error) {
	return s.repo.Downloads(ctx)
}

func (s *AdminService) UpdateDownload(ctx context.Context, platform string, release domain.DownloadRelease) (domain.DownloadRelease, error) {
	platform = strings.TrimSpace(strings.ToLower(platform))
	if platform == "" {
		return domain.DownloadRelease{}, InvalidRequest("平台不能为空")
	}
	if release.FileName == "" || release.Version == "" || release.DownloadURL == "" {
		return domain.DownloadRelease{}, InvalidRequest("下载文件名、版本号和下载地址不能为空")
	}
	if existing, err := s.repo.DownloadByPlatform(ctx, platform); err == nil {
		release.SizeBytes = existing.SizeBytes
	} else if err != store.ErrNotFound {
		return domain.DownloadRelease{}, err
	}
	release.Platform = platform
	return s.repo.UpsertDownload(ctx, release)
}

func (s *AdminService) UploadDownload(ctx context.Context, platform, version, fileName string, reader io.Reader) (domain.DownloadRelease, error) {
	platform = strings.TrimSpace(strings.ToLower(platform))
	version = strings.TrimSpace(version)
	fileName = filepath.Base(strings.TrimSpace(fileName))
	if platform == "" {
		return domain.DownloadRelease{}, InvalidRequest("平台不能为空")
	}
	if version == "" {
		return domain.DownloadRelease{}, InvalidRequest("版本号不能为空")
	}
	if fileName == "" || fileName == "." || fileName == string(filepath.Separator) {
		return domain.DownloadRelease{}, InvalidRequest("安装包文件名不能为空")
	}
	if err := validateDownloadFileType(platform, fileName); err != nil {
		return domain.DownloadRelease{}, err
	}
	if reader == nil {
		return domain.DownloadRelease{}, InvalidRequest("安装包文件不能为空")
	}
	downloadDir := filepath.Join(s.dataDir, "downloads")
	if err := os.MkdirAll(downloadDir, 0o755); err != nil {
		return domain.DownloadRelease{}, err
	}
	targetPath := filepath.Join(downloadDir, fileName)
	target, err := os.Create(targetPath)
	if err != nil {
		return domain.DownloadRelease{}, err
	}
	defer target.Close()
	sizeBytes, err := io.Copy(target, reader)
	if err != nil {
		return domain.DownloadRelease{}, err
	}
	return s.repo.UpsertDownload(ctx, domain.DownloadRelease{
		Platform:    platform,
		FileName:    fileName,
		Version:     version,
		DownloadURL: "/downloads/" + fileName,
		SizeBytes:   sizeBytes,
	})
}

func (s *AdminService) DeleteDownloadFile(ctx context.Context, platform string) (domain.DownloadRelease, error) {
	platform = strings.TrimSpace(strings.ToLower(platform))
	if platform == "" {
		return domain.DownloadRelease{}, InvalidRequest("平台不能为空")
	}
	release, err := s.repo.DownloadByPlatform(ctx, platform)
	if err != nil {
		if err == store.ErrNotFound {
			return domain.DownloadRelease{}, NotFound("该平台还没有上传安装包")
		}
		return domain.DownloadRelease{}, err
	}
	targetPath := filepath.Join(s.dataDir, "downloads", filepath.Base(release.FileName))
	if err := os.Remove(targetPath); err != nil && !os.IsNotExist(err) {
		return domain.DownloadRelease{}, err
	}
	if err := s.repo.DeleteDownload(ctx, platform); err != nil {
		return domain.DownloadRelease{}, err
	}
	release.SizeBytes = 0
	return release, nil
}

func validateDownloadFileType(platform, fileName string) error {
	ext := strings.ToLower(filepath.Ext(fileName))
	switch platform {
	case "android":
		if ext != ".apk" {
			return InvalidRequest("Android 安装包必须是 .apk 文件")
		}
	case "macos":
		if ext != ".dmg" {
			return InvalidRequest("macOS 安装包必须是 .dmg 文件")
		}
	case "windows":
		if ext != ".exe" {
			return InvalidRequest("Windows 安装包必须是 .exe 文件")
		}
	case "linux":
		if ext != ".appimage" {
			return InvalidRequest("Linux 安装包必须是 .AppImage 文件")
		}
	default:
		return InvalidRequest("平台只能是 android、macos、windows 或 linux")
	}
	return nil
}

func intSetting(values map[string]string, key string, fallback int64) int64 {
	value, ok := values[key]
	if !ok || value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return fallback
	}
	return parsed
}

func stringSetting(values map[string]string, key, fallback string) string {
	value, ok := values[key]
	if !ok || value == "" {
		return fallback
	}
	return value
}

func int64FromAny(value any) (int64, bool) {
	switch typed := value.(type) {
	case float64:
		return int64(typed), true
	case int64:
		return typed, true
	case int:
		return int64(typed), true
	default:
		return 0, false
	}
}

func dirSize(root string) (int64, error) {
	if strings.TrimSpace(root) == "" {
		return 0, nil
	}
	var total int64
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		total += info.Size()
		return nil
	})
	if os.IsNotExist(err) {
		return 0, nil
	}
	return total, err
}
