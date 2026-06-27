package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
	"github.com/ligson/vaultsync/internal/token"
)

const sessionTTL = 24 * time.Hour

type AuthService struct {
	repo        *store.AuthRepo
	tokenSecret []byte
	now         func() time.Time
}

func NewAuthService(repo *store.AuthRepo, tokenSecret string) *AuthService {
	return &AuthService{
		repo:        repo,
		tokenSecret: []byte(tokenSecret),
		now:         func() time.Time { return time.Now().UTC() },
	}
}

func (s *AuthService) Register(ctx context.Context, email, password string) (domain.User, error) {
	email = strings.TrimSpace(strings.ToLower(email))
	if email == "" {
		return domain.User{}, InvalidRequest("email is required")
	}
	if password == "" {
		return domain.User{}, InvalidRequest("password is required")
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return domain.User{}, err
	}

	user := domain.User{
		ID:           newID(),
		Email:        email,
		PasswordHash: string(hash),
		CreatedAt:    s.now().Format(time.RFC3339),
	}
	return s.repo.CreateUser(ctx, user)
}

func (s *AuthService) Login(ctx context.Context, email, password string) (domain.SessionToken, error) {
	user, err := s.repo.FindUserByEmail(ctx, strings.TrimSpace(strings.ToLower(email)))
	if err != nil {
		return domain.SessionToken{}, Unauthorized("invalid email or password")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return domain.SessionToken{}, Unauthorized("invalid email or password")
	}

	now := s.now()
	expiresAt := now.Add(sessionTTL)
	tokenID := newID()
	deviceID := ""
	value, err := token.Create(s.tokenSecret, tokenID, user.ID, deviceID, expiresAt)
	if err != nil {
		return domain.SessionToken{}, err
	}
	if err := s.repo.CreateSession(ctx, tokenID, user.ID, deviceID, now.Format(time.RFC3339), expiresAt.Format(time.RFC3339)); err != nil {
		return domain.SessionToken{}, err
	}

	return domain.SessionToken{
		Token:     value,
		TokenID:   tokenID,
		UserID:    user.ID,
		ExpiresAt: expiresAt.Format(time.RFC3339),
	}, nil
}

func (s *AuthService) VerifyToken(value string) (token.Claims, error) {
	return token.Verify(s.tokenSecret, value, s.now())
}

func newID() string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(bytes[:])
}
