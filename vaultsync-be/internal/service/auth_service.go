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
	repo                     *store.AuthRepo
	tokenSecret              []byte
	adminRegistrationEnabled bool
	defaultUserQuotaBytes    int64
	now                      func() time.Time
}

type AuthOptions struct {
	AdminRegistrationEnabled bool
	DefaultUserQuotaBytes    int64
}

func NewAuthService(repo *store.AuthRepo, tokenSecret string, options ...AuthOptions) *AuthService {
	opts := AuthOptions{
		AdminRegistrationEnabled: true,
		DefaultUserQuotaBytes:    100 * 1024 * 1024 * 1024,
	}
	if len(options) > 0 {
		opts = options[0]
		if opts.DefaultUserQuotaBytes == 0 {
			opts.DefaultUserQuotaBytes = 100 * 1024 * 1024 * 1024
		}
	}
	return &AuthService{
		repo:                     repo,
		tokenSecret:              []byte(tokenSecret),
		adminRegistrationEnabled: opts.AdminRegistrationEnabled,
		defaultUserQuotaBytes:    opts.DefaultUserQuotaBytes,
		now:                      func() time.Time { return time.Now().UTC() },
	}
}

func (s *AuthService) Register(ctx context.Context, email, password string) (domain.User, error) {
	return s.RegisterUserWithQuota(ctx, email, password, s.defaultUserQuotaBytes)
}

func (s *AuthService) RegisterUserWithQuota(ctx context.Context, email, password string, quotaBytes int64) (domain.User, error) {
	if quotaBytes < 0 {
		return domain.User{}, InvalidRequest("用户限额不能小于 0")
	}
	return s.registerWithRoleAndQuota(ctx, email, password, "user", quotaBytes)
}

func (s *AuthService) RegisterAdmin(ctx context.Context, email, password string) (domain.User, error) {
	if !s.adminRegistrationEnabled {
		return domain.User{}, Forbidden("管理员注册已关闭")
	}
	user, err := s.registerWithRole(ctx, email, password, "admin")
	if err != nil {
		return domain.User{}, err
	}
	return user, nil
}

func (s *AuthService) registerWithRole(ctx context.Context, email, password, role string) (domain.User, error) {
	return s.registerWithRoleAndQuota(ctx, email, password, role, s.defaultUserQuotaBytes)
}

func (s *AuthService) registerWithRoleAndQuota(ctx context.Context, email, password, role string, quotaBytes int64) (domain.User, error) {
	email = strings.TrimSpace(strings.ToLower(email))
	if email == "" {
		return domain.User{}, InvalidRequest("邮箱不能为空")
	}
	if password == "" {
		return domain.User{}, InvalidRequest("密码不能为空")
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return domain.User{}, err
	}

	user := domain.User{
		ID:           newID(),
		Email:        email,
		PasswordHash: string(hash),
		Role:         role,
		Status:       "active",
		QuotaBytes:   quotaBytes,
		UsedBytes:    0,
		CreatedAt:    s.now().Format(time.RFC3339),
	}
	return s.repo.CreateUser(ctx, user)
}

func (s *AuthService) ResetPassword(ctx context.Context, userID, password string) error {
	if strings.TrimSpace(password) == "" {
		return InvalidRequest("密码不能为空")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if err := s.repo.UpdatePasswordHash(ctx, userID, string(hash)); err != nil {
		if err == store.ErrNotFound {
			return NotFound("用户不存在")
		}
		return err
	}
	return nil
}

func (s *AuthService) Login(ctx context.Context, email, password string) (domain.SessionToken, error) {
	return s.login(ctx, email, password, "")
}

func (s *AuthService) LoginAdmin(ctx context.Context, email, password string) (domain.SessionToken, error) {
	return s.login(ctx, email, password, "admin")
}

func (s *AuthService) login(ctx context.Context, email, password, requiredRole string) (domain.SessionToken, error) {
	user, err := s.repo.FindUserByEmail(ctx, strings.TrimSpace(strings.ToLower(email)))
	if err != nil {
		return domain.SessionToken{}, Unauthorized("invalid email or password")
	}
	if user.Status != "active" {
		return domain.SessionToken{}, Forbidden("账号已被禁用")
	}
	if requiredRole != "" && user.Role != requiredRole {
		return domain.SessionToken{}, Forbidden("没有管理员权限")
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

func (s *AuthService) UserByID(ctx context.Context, id string) (domain.User, error) {
	user, err := s.repo.FindUserByID(ctx, id)
	if err != nil {
		return domain.User{}, Unauthorized("invalid user")
	}
	return user, nil
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
