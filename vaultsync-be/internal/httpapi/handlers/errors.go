package handlers

import (
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

const (
	errorCodeInvalidRequest = service.CodeInvalidRequest
)

func writeError(w http.ResponseWriter, status int, code, message string) {
	response.Write(w, status, message, map[string]any{
		"code": code,
	})
}

func writeServiceError(w http.ResponseWriter, err error) {
	appErr := service.ToAppError(err)
	writeError(w, appErr.Status, appErr.Code, appErr.Message)
}
