package maintenance

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ligson/vaultsync/internal/storage"
)

type UploadSessionRepairMode string

const (
	UploadSessionRepairDryRun UploadSessionRepairMode = "dry-run"
	UploadSessionRepairApply  UploadSessionRepairMode = "apply"
)

type UploadSessionRepairOptions struct {
	DataDir       string
	StoredDataDir string
	Mode          UploadSessionRepairMode
	Now           func() time.Time
}

type UploadSessionRepairSummary struct {
	Mode             UploadSessionRepairMode
	Scanned          int
	Repairable       int
	Repaired         int
	Skipped          int
	Errors           int
	BackupPath       string
	NeedsManualCheck []string
}

type repairUploadSessionRow struct {
	ID                string
	UserID            string
	DeviceID          string
	SyncRootID        string
	ObjectID          string
	VersionID         string
	TotalSize         int64
	ReceivedSize      int64
	MetadataJSON      string
	CreatedAt         string
	EncryptionEnabled bool
	ExistingVersionID string
	ExistingSizeBytes int64
}

func RunUploadSessionRepair(ctx context.Context, db *sql.DB, opts UploadSessionRepairOptions) (UploadSessionRepairSummary, error) {
	if opts.Now == nil {
		opts.Now = func() time.Time { return time.Now().UTC() }
	}
	if err := validateUploadSessionRepairOptions(opts); err != nil {
		return UploadSessionRepairSummary{}, err
	}
	summary := UploadSessionRepairSummary{Mode: opts.Mode}
	rows, err := loadRepairableUploadSessions(ctx, db)
	if err != nil {
		return summary, err
	}
	if opts.Mode == UploadSessionRepairApply {
		backupDir := filepath.Join(cleanPath(opts.DataDir), "backups", "upload-session-repair-"+opts.Now().Format("20060102-150405"))
		if err := ensureDir(backupDir); err != nil {
			return summary, err
		}
		summary.BackupPath = filepath.Join(backupDir, "vaultsync.db")
		if err := backupSQLite(ctx, db, summary.BackupPath); err != nil {
			return summary, err
		}
	}

	fs := storage.NewFSStorage(cleanPath(opts.DataDir))
	for _, row := range rows {
		summary.Scanned++
		if row.ExistingVersionID != "" {
			summary.Repairable++
			if opts.Mode == UploadSessionRepairApply {
				if err := markRecoveredUploadSessionCompleted(ctx, db, row); err != nil {
					summary.Errors++
					summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：更新已有版本会话状态失败："+err.Error())
					continue
				}
				summary.Repaired++
			}
			continue
		}
		relativePath := ""
		if !row.EncryptionEnabled {
			var err error
			relativePath, err = metadataString(row.MetadataJSON, "relative_path")
			if err != nil {
				summary.Errors++
				summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：普通存储缺少相对路径")
				continue
			}
		}
		placement := storage.UploadObjectPlacement{
			UserID:       row.UserID,
			DeviceID:     row.DeviceID,
			SyncRootID:   row.SyncRootID,
			SessionID:    row.ID,
			ObjectID:     row.ObjectID,
			VersionID:    row.VersionID,
			RelativePath: relativePath,
			Encrypted:    row.EncryptionEnabled,
			ExpectedSize: row.TotalSize,
		}
		var (
			contentPath string
			hashValue   string
			size        int64
		)
		if opts.Mode == UploadSessionRepairDryRun {
			contentPath, hashValue, size, err = fs.InspectRecoverableUpload(placement)
		} else {
			contentPath, hashValue, size, err = fs.FinalizeUpload(placement)
		}
		if err != nil {
			summary.Skipped++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：正式文件不可恢复："+err.Error())
			continue
		}
		encryptedName, err := metadataString(row.MetadataJSON, "encrypted_name")
		if err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：缺少加密文件名")
			continue
		}
		storedPath, err := toStoredContentPath(contentPath, opts.DataDir, opts.StoredDataDir)
		if err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：转换数据库存储路径失败："+err.Error())
			continue
		}
		summary.Repairable++
		if opts.Mode == UploadSessionRepairDryRun {
			continue
		}
		if err := completeRecoveredUploadSession(ctx, db, row, encryptedName, storedPath, hashValue, size); err != nil {
			summary.Errors++
			summary.NeedsManualCheck = append(summary.NeedsManualCheck, row.ID+"：写入数据库失败："+err.Error())
			continue
		}
		summary.Repaired++
	}
	return summary, nil
}

func validateUploadSessionRepairOptions(opts UploadSessionRepairOptions) error {
	if strings.TrimSpace(opts.DataDir) == "" {
		return errors.New("数据目录不能为空")
	}
	if strings.TrimSpace(opts.StoredDataDir) == "" {
		return errors.New("数据库中的数据目录前缀不能为空")
	}
	switch opts.Mode {
	case UploadSessionRepairDryRun, UploadSessionRepairApply:
		return nil
	default:
		return fmt.Errorf("不支持的修复模式：%s", opts.Mode)
	}
}

func loadRepairableUploadSessions(ctx context.Context, db *sql.DB) ([]repairUploadSessionRow, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT us.id, us.user_id, us.device_id, us.sync_root_id, us.object_id,
			us.version_id, us.total_size, us.received_size, us.metadata_json,
			us.created_at, sr.encryption_enabled, fv.id, fv.size_bytes
		FROM upload_sessions us
		JOIN sync_roots sr ON sr.id = us.sync_root_id
		LEFT JOIN file_versions fv ON fv.id = us.version_id
		WHERE us.status = 'pending'
			AND us.received_size = us.total_size
		ORDER BY us.rowid
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	result := []repairUploadSessionRow{}
	for rows.Next() {
		var row repairUploadSessionRow
		var encryptionEnabled int
		var existingVersionID sql.NullString
		var existingSizeBytes sql.NullInt64
		if err := rows.Scan(&row.ID, &row.UserID, &row.DeviceID, &row.SyncRootID, &row.ObjectID, &row.VersionID, &row.TotalSize, &row.ReceivedSize, &row.MetadataJSON, &row.CreatedAt, &encryptionEnabled, &existingVersionID, &existingSizeBytes); err != nil {
			return nil, err
		}
		row.EncryptionEnabled = encryptionEnabled != 0
		if existingVersionID.Valid {
			row.ExistingVersionID = existingVersionID.String
		}
		if existingSizeBytes.Valid {
			row.ExistingSizeBytes = existingSizeBytes.Int64
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

func metadataString(metadataJSON, key string) (string, error) {
	payload := map[string]any{}
	if err := json.Unmarshal([]byte(metadataJSON), &payload); err != nil {
		return "", err
	}
	value, _ := payload[key].(string)
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s 不能为空", key)
	}
	return value, nil
}

func toStoredContentPath(physicalPath, dataDir, storedDataDir string) (string, error) {
	physicalClean := cleanPath(physicalPath)
	dataClean := cleanPath(dataDir)
	rel, err := filepath.Rel(dataClean, physicalClean)
	if err != nil {
		return "", err
	}
	if rel == "." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", fmt.Errorf("路径 %s 不在数据目录 %s 下", physicalPath, dataDir)
	}
	return filepath.ToSlash(filepath.Join(cleanPath(storedDataDir), rel)), nil
}

func completeRecoveredUploadSession(ctx context.Context, db *sql.DB, row repairUploadSessionRow, encryptedName, contentPath, hashValue string, size int64) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var existingSizeBytes int64
	err = tx.QueryRowContext(ctx, `
		SELECT size_bytes
		FROM file_versions
		WHERE user_id = ? AND id = ?
	`, row.UserID, row.VersionID).Scan(&existingSizeBytes)
	if err == nil {
		if _, err := tx.ExecContext(ctx, `
			UPDATE upload_sessions
			SET status = 'completed', received_size = ?
			WHERE user_id = ? AND id = ?
		`, existingSizeBytes, row.UserID, row.ID); err != nil {
			return err
		}
		return tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO file_versions (
			id, user_id, sync_root_id, object_id, encrypted_name,
			content_path, content_hash, size_bytes, metadata_json, created_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, row.VersionID, row.UserID, row.SyncRootID, row.ObjectID, encryptedName, contentPath, hashValue, size, row.MetadataJSON, row.CreatedAt); err != nil {
		return err
	}
	eventID, err := repairID()
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO sync_events (
			id, user_id, change_type, version_id, tombstone_id,
			sync_root_id, object_id, created_at
		)
		VALUES (?, ?, 'upsert', ?, '', ?, ?, ?)
	`, eventID, row.UserID, row.VersionID, row.SyncRootID, row.ObjectID, row.CreatedAt); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE upload_sessions
		SET status = 'completed', received_size = ?
		WHERE user_id = ? AND id = ?
	`, size, row.UserID, row.ID); err != nil {
		return err
	}
	return tx.Commit()
}

func markRecoveredUploadSessionCompleted(ctx context.Context, db *sql.DB, row repairUploadSessionRow) error {
	_, err := db.ExecContext(ctx, `
		UPDATE upload_sessions
		SET status = 'completed', received_size = ?
		WHERE user_id = ? AND id = ? AND status = 'pending'
	`, row.ExistingSizeBytes, row.UserID, row.ID)
	return err
}

func repairID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func ensureDir(path string) error {
	return os.MkdirAll(path, 0o755)
}
