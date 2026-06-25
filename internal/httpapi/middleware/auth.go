package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/ligson/vaultsync/internal/token"
)

type contextKey string

const userIDKey contextKey = "user_id"

func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

func MustUserID(ctx context.Context) string {
	userID, ok := ctx.Value(userIDKey).(string)
	if !ok || userID == "" {
		panic("missing authenticated user id")
	}
	return userID
}

type TokenVerifier interface {
	VerifyToken(value string) (token.Claims, error)
}

func Auth(tokenVerifier TokenVerifier, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		tokenValue, ok := strings.CutPrefix(header, "Bearer ")
		if !ok || tokenValue == "" {
			http.Error(w, "missing bearer token", http.StatusUnauthorized)
			return
		}

		claims, err := tokenVerifier.VerifyToken(tokenValue)
		if err != nil {
			http.Error(w, "invalid bearer token", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r.WithContext(WithUserID(r.Context(), claims.UserID)))
	})
}
