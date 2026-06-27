package service

import (
	"context"
	"database/sql"
	"io"
	"os"
	"path/filepath"
)

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
		if err == sql.ErrNoRows {
			return nil, NotFound("object version not found")
		}
		return nil, err
	}

	if !filepath.IsAbs(contentPath) {
		contentPath = filepath.Join(s.dataDir, contentPath)
	}
	return os.Open(contentPath)
}
