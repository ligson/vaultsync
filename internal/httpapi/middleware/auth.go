package middleware

import (
	"context"
	"encoding/json"
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
			writeAuthError(w, "missing bearer token")
			return
		}

		claims, err := tokenVerifier.VerifyToken(tokenValue)
		if err != nil {
			writeAuthError(w, "invalid bearer token")
			return
		}

		next.ServeHTTP(w, r.WithContext(WithUserID(r.Context(), claims.UserID)))
	})
}

func writeAuthError(w http.ResponseWriter, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{
			"code":    "unauthorized",
			"message": message,
		},
	})
}
