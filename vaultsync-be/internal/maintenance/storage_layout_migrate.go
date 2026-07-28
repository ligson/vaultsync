package maintenance

import (
	"bufio"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const legacyDeviceID = "__legacy_device__"

type StorageLayoutMode string

const (
	StorageLayoutDryRun  StorageLayoutMode = "dry-run"
	StorageLayoutApply   StorageLayoutMode = "apply"
	StorageLayoutCleanup StorageLayoutMode = "cleanup"
)

type StorageLayoutOptions struct {
	DataDir       string
	StoredDataDir string
	ReportPath    string
	Mode          StorageLayoutMode
	Now           func() time.Time
}

type StorageLayoutSummary struct {
	Mode             StorageLayoutMode
	Scanned          int
	Planned          int
	Migrated         int
	Mirrored         int
	Skipped          int
	Deleted          int
	Errors           int
	BackupPath       string
	ReportPath       string
	NeedsManualCheck []string
}

type storageVersionRow struct {
	RowID             int64
	ID                string
	UserID            string
	SyncRootID        string
	ObjectID          string
	ContentPath       string
	ContentHash       string
	SizeBytes         int64
	MetadataJSON      string
	DeviceID          string
	EncryptionEnabled int
}

type storageMigrationRecord struct {
	VersionID       string `json:"version_id"`
	UserID          string `json:"user_id"`
	SyncRootID      string `json:"sync_root_id"`
	ObjectID        string `json:"object_id"`
	StorageKind     string `json:"storage_kind"`
	OldStoredPath   string `json:"old_stored_path"`
	NewStoredPath   string `json:"new_stored_path"`
	OldPhysicalPath string `json:"old_physical_path"`
	NewPhysicalPath string `json:"new_physical_path"`
	MirrorPath      string `json:"mirror_path,omitempty"`
	ContentHash     string `json:"content_hash"`
	SizeBytes       int64  `json:"size_bytes"`
	Action          string `json:"action"`
}

func RunStorageLayoutMigration(ctx context.Context, db *sql.DB, opts StorageLayoutOptions) (StorageLayoutSummary, error) {
	if opts.Now == nil {
		opts.Now = func() time.Time { return time.Now().UTC() }
	}
	if err := validateStorageLayoutOptions(opts); err != nil {
		return StorageLayoutSummary{}, err
	}
	switch opts.Mode {
	case StorageLayoutDryRun, StorageLayoutApply:
		return planAndApplyStorageLayout(ctx, db, opts)
	case StorageLayoutCleanup:
		return cleanupStorageLayout(ctx, db, opts)
	default:
		return StorageLayoutSummary{}, fmt.Errorf("不支持的迁移模式：%s", opts.Mode)
	}
}

func validateStorageLayoutOptions(opts StorageLayoutOptions) error {
	if strings.TrimSpace(opts.DataDir) == "" {
		return errors.New("数据目录不能为空")
	}
	if strings.TrimSpace(opts.StoredDataDir) == "" {
		return errors.New("数据库中的数据目录前缀不能为空")
	}
	if opts.Mode == StorageLayoutCleanup && strings.TrimSpace(opts.ReportPath) == "" {
		return errors.New("cleanup 模式必须指定 apply 阶段生成的 report 文件")
	}
	return nil
}

func planAndApplyStorageLayout(ctx context.Context, db *sql.DB, opts StorageLayoutOptions) (StorageLayoutSummary, error) {
	summary := StorageLayoutSummary{Mode: opts.Mode}
	rows, err := loadStorageVersionRows(ctx, db)
	if err != nil {
		return summary, err
	}
	tombstones, err := loadStorageTombstones(ctx, db)
	if err != nil {
		return summary, err
	}
	latest := latestRows(rows, tombstones)

	reportPath := opts.ReportPath
	backupPath := ""
	if opts.Mode == StorageLayoutApply {
		backupDir := filepath.Join(cleanPath(opts.DataDir), "backups", "storage-layout-"+opts.Now().Format("20060102-150405"))
		if err := os.MkdirAll(backupDir, 0o755); err != nil {
			return summary, err
		}
		backupPath = filepath.Join(backupDir, "vaultsync.db")
		if err := backupSQLite(ctx, db, backupPath); err != nil {
			return summary, err
		}
		if reportPath == "" {
			reportPath = filepath.Join(backupDir, "migration-report.jsonl")
		}
	}
	summary.BackupPath = backupPath
	summary.ReportPath = reportPath

	var report *os.File
	if reportPath != "" {
		report, err = os.OpenFile(reportPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return summary, err
		}
		defer report.Close()
	}

	for _, row := range rows {
		summary.Scanned++
		record, mirrorPhysical, err := planStorageRecord(opts, row, latest[storageObjectKey(row)])
		if err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：%v", row.ID, err))
			continue
		}
		if record.Action == "skip" {
			summary.Skipped++
			continue
		}
		summary.Planned++
		if report != nil {
			if err := writeMigrationRecord(report, record); err != nil {
				return summary, err
			}
		}
		if opts.Mode == StorageLayoutDryRun {
			continue
		}
		if err := copyAndValidate(record.OldPhysicalPath, record.NewPhysicalPath, row.ContentHash, row.SizeBytes); err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：复制并校验失败：%v", row.ID, err))
			continue
		}
		if mirrorPhysical != "" {
			if err := copyAndValidate(record.NewPhysicalPath, mirrorPhysical, row.ContentHash, row.SizeBytes); err != nil {
				summary.Errors++
				summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：生成普通目录镜像失败：%v", row.ID, err))
				continue
			}
			summary.Mirrored++
		}
		if record.OldStoredPath != record.NewStoredPath {
			if err := updateContentPath(ctx, db, row.ID, record.NewStoredPath); err != nil {
				summary.Errors++
				summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：更新数据库路径失败：%v", row.ID, err))
				continue
			}
			summary.Migrated++
		} else {
			summary.Skipped++
		}
	}
	return summary, nil
}

func cleanupStorageLayout(ctx context.Context, db *sql.DB, opts StorageLayoutOptions) (StorageLayoutSummary, error) {
	summary := StorageLayoutSummary{Mode: StorageLayoutCleanup, ReportPath: opts.ReportPath}
	file, err := os.Open(opts.ReportPath)
	if err != nil {
		return summary, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var record storageMigrationRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("报告行解析失败：%v", err))
			continue
		}
		summary.Scanned++
		if record.OldStoredPath == "" || record.OldStoredPath == record.NewStoredPath {
			summary.Skipped++
			continue
		}
		referenced, err := contentPathReferenced(ctx, db, record.OldStoredPath)
		if err != nil {
			return summary, err
		}
		if referenced {
			summary.Skipped++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, record.OldStoredPath+" 仍被数据库引用，已跳过删除")
			continue
		}
		if err := validateFileHash(record.NewPhysicalPath, record.ContentHash, record.SizeBytes); err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：新文件校验失败，已跳过删除：%v", record.VersionID, err))
			continue
		}
		if err := removeLegacyObject(record.OldPhysicalPath, opts.DataDir); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				summary.Skipped++
				continue
			}
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, fmt.Sprintf("%s：删除旧文件失败：%v", record.VersionID, err))
			continue
		}
		summary.Deleted++
	}
	if err := scanner.Err(); err != nil {
		return summary, err
	}
	return summary, nil
}

func loadStorageVersionRows(ctx context.Context, db *sql.DB) ([]storageVersionRow, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT fv.rowid, fv.id, fv.user_id, fv.sync_root_id, fv.object_id,
			fv.content_path, fv.content_hash, fv.size_bytes, fv.metadata_json,
			COALESCE(sr.device_id, ''), COALESCE(sr.encryption_enabled, -1)
		FROM file_versions fv
		LEFT JOIN sync_roots sr ON sr.id = fv.sync_root_id
		ORDER BY fv.rowid
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]storageVersionRow, 0)
	for rows.Next() {
		var item storageVersionRow
		if err := rows.Scan(&item.RowID, &item.ID, &item.UserID, &item.SyncRootID, &item.ObjectID, &item.ContentPath, &item.ContentHash, &item.SizeBytes, &item.MetadataJSON, &item.DeviceID, &item.EncryptionEnabled); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func loadStorageTombstones(ctx context.Context, db *sql.DB) (map[string]bool, error) {
	rows, err := db.QueryContext(ctx, `SELECT user_id, sync_root_id, object_id FROM file_tombstones`)
	if err != nil {
		if strings.Contains(err.Error(), "no such table") {
			return map[string]bool{}, nil
		}
		return nil, err
	}
	defer rows.Close()

	tombstones := map[string]bool{}
	for rows.Next() {
		var userID, syncRootID, objectID string
		if err := rows.Scan(&userID, &syncRootID, &objectID); err != nil {
			return nil, err
		}
		tombstones[userID+"|"+syncRootID+"|"+objectID] = true
	}
	return tombstones, rows.Err()
}

func latestRows(rows []storageVersionRow, tombstones map[string]bool) map[string]int64 {
	latest := map[string]int64{}
	for _, row := range rows {
		key := storageObjectKey(row)
		if tombstones[key] {
			continue
		}
		if row.RowID > latest[key] {
			latest[key] = row.RowID
		}
	}
	return latest
}

func storageObjectKey(row storageVersionRow) string {
	return row.UserID + "|" + row.SyncRootID + "|" + row.ObjectID
}

func planStorageRecord(opts StorageLayoutOptions, row storageVersionRow, latestRowID int64) (storageMigrationRecord, string, error) {
	oldPhysical, err := physicalPathForStored(opts, row.ContentPath)
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	if err := validateFileHash(oldPhysical, row.ContentHash, row.SizeBytes); err != nil {
		return storageMigrationRecord{}, "", err
	}
	meta, err := parseMetadata(row.MetadataJSON)
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	userID, err := safeStorageSegment(row.UserID, "user_id")
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	syncRootID, err := safeStorageSegment(row.SyncRootID, "sync_root_id")
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	objectID, err := safeStorageSegment(row.ObjectID, "object_id")
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	versionID, err := safeStorageSegment(row.ID, "version_id")
	if err != nil {
		return storageMigrationRecord{}, "", err
	}

	relativePath, _ := meta["relative_path"].(string)
	deviceID := row.DeviceID
	if strings.TrimSpace(deviceID) == "" {
		deviceID = legacyDeviceID
	}
	deviceID, err = safeStorageSegment(deviceID, "device_id")
	if err != nil {
		return storageMigrationRecord{}, "", err
	}

	var targetPhysical string
	var mirrorPhysical string
	storageKind := "encrypted"
	if row.EncryptionEnabled == 0 || (row.EncryptionEnabled < 0 && strings.TrimSpace(relativePath) != "") {
		relativePath, err = safeStorageRelativePath(relativePath)
		if err != nil {
			return storageMigrationRecord{}, "", err
		}
		fileName := filepath.Base(relativePath)
		targetPhysical = filepath.Join(cleanPath(opts.DataDir), "objects", userID, "plain", deviceID, syncRootID, ".vaultsync_versions", objectID, versionID, fileName)
		storageKind = "plain"
		if latestRowID == row.RowID && row.EncryptionEnabled == 0 {
			mirrorPhysical = filepath.Join(cleanPath(opts.DataDir), "objects", userID, "plain", deviceID, syncRootID, relativePath)
		}
	} else {
		targetPhysical = filepath.Join(cleanPath(opts.DataDir), "objects", userID, "encrypted", deviceID, syncRootID, versionID+".bin")
	}
	newStored, err := storedPathForPhysical(opts, targetPhysical)
	if err != nil {
		return storageMigrationRecord{}, "", err
	}
	oldStored := cleanStoredPath(row.ContentPath)
	action := "migrate"
	if oldStored == newStored && mirrorPhysical == "" {
		action = "skip"
	}
	return storageMigrationRecord{
		VersionID:       row.ID,
		UserID:          row.UserID,
		SyncRootID:      row.SyncRootID,
		ObjectID:        row.ObjectID,
		StorageKind:     storageKind,
		OldStoredPath:   oldStored,
		NewStoredPath:   newStored,
		OldPhysicalPath: oldPhysical,
		NewPhysicalPath: targetPhysical,
		MirrorPath:      mirrorPhysical,
		ContentHash:     row.ContentHash,
		SizeBytes:       row.SizeBytes,
		Action:          action,
	}, mirrorPhysical, nil
}

func parseMetadata(raw string) (map[string]any, error) {
	payload := map[string]any{}
	if strings.TrimSpace(raw) == "" {
		return payload, nil
	}
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return nil, fmt.Errorf("元数据 JSON 无法解析：%w", err)
	}
	return payload, nil
}

func backupSQLite(ctx context.Context, db *sql.DB, backupPath string) error {
	if _, err := os.Stat(backupPath); err == nil {
		return fmt.Errorf("备份文件已存在：%s", backupPath)
	}
	query := fmt.Sprintf("VACUUM INTO %s", quoteSQLiteString(backupPath))
	_, err := db.ExecContext(ctx, query)
	return err
}

func updateContentPath(ctx context.Context, db *sql.DB, versionID, contentPath string) error {
	_, err := db.ExecContext(ctx, `UPDATE file_versions SET content_path = ? WHERE id = ?`, contentPath, versionID)
	return err
}

func contentPathReferenced(ctx context.Context, db *sql.DB, contentPath string) (bool, error) {
	var count int
	err := db.QueryRowContext(ctx, `SELECT count(*) FROM file_versions WHERE content_path = ?`, contentPath).Scan(&count)
	return count > 0, err
}

func writeMigrationRecord(file *os.File, record storageMigrationRecord) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}
	if _, err := file.Write(append(encoded, '\n')); err != nil {
		return err
	}
	return nil
}

func copyAndValidate(sourcePath, targetPath, expectedHash string, expectedSize int64) error {
	if err := validateFileHash(sourcePath, expectedHash, expectedSize); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(targetPath); err == nil {
		return validateFileHash(targetPath, expectedHash, expectedSize)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	tmpPath := targetPath + ".tmp"
	if err := copyFile(sourcePath, tmpPath); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := validateFileHash(tmpPath, expectedHash, expectedSize); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, targetPath)
}

func copyFile(sourcePath, targetPath string) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()
	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(target, source); err != nil {
		_ = target.Close()
		return err
	}
	return target.Close()
}

func validateFileHash(path, expectedHash string, expectedSize int64) error {
	hashValue, size, err := hashFile(path)
	if err != nil {
		return err
	}
	if expectedSize >= 0 && size != expectedSize {
		return fmt.Errorf("文件大小不一致：期望 %d，实际 %d", expectedSize, size)
	}
	if strings.TrimSpace(expectedHash) != "" && !strings.EqualFold(hashValue, expectedHash) {
		return fmt.Errorf("文件哈希不一致：期望 %s，实际 %s", expectedHash, hashValue)
	}
	return nil
}

func hashFile(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}

func removeLegacyObject(path, dataDir string) error {
	path = cleanPath(path)
	objectsRoot := filepath.Join(cleanPath(dataDir), "objects")
	rel, err := filepath.Rel(objectsRoot, path)
	if err != nil {
		return err
	}
	if rel == "." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || rel == ".." {
		return fmt.Errorf("拒绝删除 objects 目录外的文件：%s", path)
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	cleanupEmptyParents(filepath.Dir(path), objectsRoot)
	return nil
}

func cleanupEmptyParents(dir, stopDir string) {
	dir = cleanPath(dir)
	stopDir = cleanPath(stopDir)
	for dir != stopDir {
		if err := os.Remove(dir); err != nil {
			return
		}
		dir = filepath.Dir(dir)
	}
}

func physicalPathForStored(opts StorageLayoutOptions, storedPath string) (string, error) {
	storedPath = cleanStoredPath(storedPath)
	dataDir := cleanPath(opts.DataDir)
	storedDataDir := cleanPath(opts.StoredDataDir)
	if filepath.IsAbs(storedPath) {
		if storedPath == storedDataDir {
			return dataDir, nil
		}
		if strings.HasPrefix(storedPath, storedDataDir+string(os.PathSeparator)) {
			rel, err := filepath.Rel(storedDataDir, storedPath)
			if err != nil {
				return "", err
			}
			return filepath.Join(dataDir, rel), nil
		}
		if storedPath == dataDir || strings.HasPrefix(storedPath, dataDir+string(os.PathSeparator)) {
			return storedPath, nil
		}
		return "", fmt.Errorf("数据库路径不在数据目录前缀内：%s", storedPath)
	}
	return filepath.Join(dataDir, storedPath), nil
}

func storedPathForPhysical(opts StorageLayoutOptions, physicalPath string) (string, error) {
	dataDir := cleanPath(opts.DataDir)
	physicalPath = cleanPath(physicalPath)
	rel, err := filepath.Rel(dataDir, physicalPath)
	if err != nil {
		return "", err
	}
	if rel == "." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || rel == ".." {
		return "", fmt.Errorf("目标路径不在数据目录内：%s", physicalPath)
	}
	return filepath.Join(cleanPath(opts.StoredDataDir), rel), nil
}

func cleanStoredPath(path string) string {
	return cleanPath(strings.TrimSpace(path))
}

func cleanPath(path string) string {
	return filepath.Clean(strings.TrimSpace(path))
}

func safeStorageSegment(value, name string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" || value == "." || value == ".." {
		return "", fmt.Errorf("%s 为空或非法", name)
	}
	if strings.ContainsAny(value, `/\`) {
		return "", fmt.Errorf("%s 包含路径分隔符", name)
	}
	return value, nil
}

func safeStorageRelativePath(value string) (string, error) {
	value = strings.ReplaceAll(strings.TrimSpace(value), "\\", "/")
	if value == "" || strings.HasPrefix(value, "/") {
		return "", errors.New("相对路径为空或是绝对路径")
	}
	cleaned := filepath.Clean(value)
	cleaned = strings.ReplaceAll(cleaned, "\\", "/")
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", errors.New("相对路径越过同步目录")
	}
	for _, segment := range strings.Split(cleaned, "/") {
		if segment == "" || segment == "." || segment == ".." || segment == ".vaultsync_versions" {
			return "", errors.New("相对路径包含保留或非法目录名")
		}
	}
	return cleaned, nil
}

func quoteSQLiteString(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}
