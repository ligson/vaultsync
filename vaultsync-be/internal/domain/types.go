package domain

type User struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"`
	Role         string `json:"role"`
	Status       string `json:"status"`
	QuotaBytes   int64  `json:"quota_bytes"`
	UsedBytes    int64  `json:"used_bytes"`
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

type AuditLog struct {
	ID          string `json:"id"`
	UserID      string `json:"actor_user_id"`
	Action      string `json:"action"`
	DetailsJSON string `json:"details_json"`
	CreatedAt   string `json:"created_at"`
}

type AdminOverview struct {
	UserCount        int64      `json:"user_count"`
	DeviceCount      int64      `json:"device_count"`
	StorageBytes     int64      `json:"storage_bytes"`
	RecentErrorCount int64      `json:"recent_error_count"`
	RecentEvents     []AuditLog `json:"recent_events"`
}

type DownloadRelease struct {
	Platform    string `json:"platform"`
	FileName    string `json:"file_name"`
	Version     string `json:"version"`
	DownloadURL string `json:"download_url"`
	SizeBytes   int64  `json:"size_bytes"`
	UpdatedAt   string `json:"updated_at"`
}

type AdminSystemStatus struct {
	Status           string `json:"status"`
	HTTPAddr         string `json:"http_addr"`
	DataDir          string `json:"data_dir"`
	DatabasePath     string `json:"database_path"`
	DownloadDir      string `json:"download_dir"`
	StorageUsedBytes int64  `json:"storage_used_bytes"`
	DatabaseBytes    int64  `json:"database_bytes"`
	DownloadBytes    int64  `json:"download_bytes"`
	UserCount        int64  `json:"user_count"`
	DeviceCount      int64  `json:"device_count"`
}
