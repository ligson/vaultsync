package handlers

import (
	"encoding/json"
	"net/http"
)

const (
	errorCodeInternal       = "internal_error"
	errorCodeInvalidRequest = "invalid_request"
	errorCodeUnauthorized   = "unauthorized"
)

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": message,
		},
	})
}
