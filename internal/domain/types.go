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
