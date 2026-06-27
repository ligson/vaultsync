package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/ligson/vaultsync/internal/httpapi/response"
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
	response.Write(w, http.StatusUnauthorized, message, map[string]any{
		"code": "unauthorized",
	})
}
