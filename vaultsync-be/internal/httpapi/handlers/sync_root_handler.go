package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type SyncRootHandler struct {
	service *service.SyncRootService
}

func NewSyncRootHandler(service *service.SyncRootService) *SyncRootHandler {
	return &SyncRootHandler{service: service}
}

func (h *SyncRootHandler) Create(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	var req struct {
		DeviceID      string `json:"device_id"`
		EncryptedPath string `json:"encrypted_path"`
		CleanupPolicy string `json:"cleanup_policy"`
		ArchivePath   string `json:"archive_path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}

	root, err := h.service.Create(r.Context(), userID, req.DeviceID, req.EncryptedPath, req.CleanupPolicy, req.ArchivePath)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusCreated, "", root)
}

func (h *SyncRootHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	roots, err := h.service.ListByUser(r.Context(), userID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{"items": roots})
}
