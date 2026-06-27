package domain

type User struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"`
	CreatedAt    string `json:"created_at"`
}

type SessionToken struct {
	Token     string `json:"token"`
	TokenID   string `json:"token_id"`
	UserID    string `json:"user_id"`
	ExpiresAt string `json:"expires_at"`
}

type Device struct {
	ID        string `json:"id"`
	UserID    string `json:"user_id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	CreatedAt string `json:"created_at"`
}

type SyncRoot struct {
	ID            string `json:"id"`
	UserID        string `json:"user_id"`
	DeviceID      string `json:"device_id"`
	EncryptedPath string `json:"encrypted_path"`
	CleanupPolicy string `json:"cleanup_policy"`
	ArchivePath   string `json:"archive_path"`
	CreatedAt     string `json:"created_at"`
}

type UploadSession struct {
	ID            string `json:"id"`
	UserID        string `json:"user_id"`
	DeviceID      string `json:"device_id"`
	SyncRootID    string `json:"sync_root_id"`
	ObjectID      string `json:"object_id"`
	VersionID     string `json:"version_id"`
	EncryptedName string `json:"encrypted_name"`
	TotalSize     int64  `json:"total_size"`
	ChunkSize     int64  `json:"chunk_size"`
	ReceivedSize  int64  `json:"received_size"`
	Status        string `json:"status"`
	MetadataJSON  string `json:"metadata_json"`
	CreatedAt     string `json:"created_at"`
}

type FileVersion struct {
	ID            string `json:"id"`
	UserID        string `json:"user_id"`
	SyncRootID    string `json:"sync_root_id"`
	ObjectID      string `json:"object_id"`
	EncryptedName string `json:"encrypted_name"`
	ContentPath   string `json:"content_path"`
	ContentHash   string `json:"content_hash"`
	SizeBytes     int64  `json:"size_bytes"`
	MetadataJSON  string `json:"metadata_json"`
	CreatedAt     string `json:"created_at"`
}

type CursorChange struct {
	CursorValue int64  `json:"cursor_value"`
	ChangeType  string `json:"change_type"`
	VersionID   string `json:"version_id"`
	ObjectID    string `json:"object_id"`
	SyncRootID  string `json:"sync_root_id"`
	CreatedAt   string `json:"created_at"`
}

type ChangePage struct {
	Items      []CursorChange `json:"items"`
	NextCursor int64          `json:"next_cursor"`
	HasMore    bool           `json:"has_more"`
}
