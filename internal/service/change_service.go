package service

import (
	"context"
	"database/sql"

	"github.com/ligson/vaultsync/internal/domain"
)

type ChangeService struct {
	db *sql.DB
}

func NewChangeService(db *sql.DB, dataDir string) *ChangeService {
	_ = dataDir
	return &ChangeService{db: db}
}

func (s *ChangeService) List(ctx context.Context, userID string, cursorValue int64) ([]domain.CursorChange, int64, error) {
	startCursor := cursorValue
	rows, err := s.db.QueryContext(ctx, `
		SELECT rowid, id, object_id, sync_root_id, created_at
		FROM file_versions
		WHERE user_id = ? AND rowid > ?
		ORDER BY rowid
	`, userID, startCursor)
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

	if len(items) > 0 && nextCursor > startCursor {
		_, err := s.db.ExecContext(ctx, `
			INSERT INTO sync_cursors (user_id, cursor_value, version_id, created_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(user_id) DO UPDATE SET
				cursor_value = excluded.cursor_value,
				version_id = excluded.version_id,
				created_at = excluded.created_at
		`, userID, nextCursor, items[len(items)-1].VersionID, items[len(items)-1].CreatedAt)
		if err != nil {
			return nil, 0, err
		}
	}
	return items, nextCursor, nil
}
