package service

import (
	"context"
	"database/sql"
	"io"
	"os"
	"path/filepath"

	"github.com/ligson/vaultsync/internal/domain"
)

type ChangeService struct {
	db      *sql.DB
	dataDir string
}

func NewChangeService(db *sql.DB, dataDir string) *ChangeService {
	return &ChangeService{db: db, dataDir: dataDir}
}

func (s *ChangeService) List(ctx context.Context, userID string, cursorValue int64) ([]domain.CursorChange, int64, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT rowid, id, object_id, sync_root_id, created_at
		FROM file_versions
		WHERE user_id = ? AND rowid > ?
		ORDER BY rowid
	`, userID, cursorValue)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	items := make([]domain.CursorChange, 0)
	var nextCursor int64 = cursorValue
	for rows.Next() {
		var change domain.CursorChange
		if err := rows.Scan(&change.CursorValue, &change.VersionID, &change.ObjectID, &change.SyncRootID, &change.CreatedAt); err != nil {
			return nil, 0, err
		}
		nextCursor = change.CursorValue
		items = append(items, change)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return items, nextCursor, nil
}

type DownloadService struct {
	db      *sql.DB
	dataDir string
}

func NewDownloadService(db *sql.DB, dataDir string) *DownloadService {
	return &DownloadService{db: db, dataDir: dataDir}
}

func (s *DownloadService) OpenCiphertext(ctx context.Context, userID, versionID string) (io.ReadCloser, error) {
	var contentPath string
	err := s.db.QueryRowContext(ctx, `
		SELECT content_path
		FROM file_versions
		WHERE user_id = ? AND id = ?
	`, userID, versionID).Scan(&contentPath)
	if err != nil {
		return nil, err
	}

	if !filepath.IsAbs(contentPath) {
		contentPath = filepath.Join(s.dataDir, contentPath)
	}
	return os.Open(contentPath)
}
