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
