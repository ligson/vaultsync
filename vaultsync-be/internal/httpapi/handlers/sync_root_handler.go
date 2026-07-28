package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

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
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
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

func (h *SyncRootHandler) UpdateCleanupPolicy(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	syncRootID := r.PathValue("syncRootID")
	var req struct {
		CleanupPolicy string `json:"cleanup_policy"`
		ArchivePath   string `json:"archive_path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	root, err := h.service.UpdateCleanupPolicy(r.Context(), userID, syncRootID, req.CleanupPolicy, req.ArchivePath)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", root)
}

func (h *SyncRootHandler) Delete(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	syncRootID := r.PathValue("syncRootID")
	deleteRemote := r.URL.Query().Get("delete_remote") == "true"
	result, err := h.service.Delete(r.Context(), userID, syncRootID, deleteRemote)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", result)
}

func (h *SyncRootHandler) ListRemoteBackupObjects(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	syncRootID := r.PathValue("syncRootID")

	cursorValue, err := parseInt64Query(r, "cursor", 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "游标参数不正确")
		return
	}
	limit, err := parseIntQuery(r, "limit", 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "分页大小参数不正确")
		return
	}

	page, err := h.service.ListRemoteBackupObjects(r.Context(), userID, syncRootID, cursorValue, limit)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", page)
}

func parseInt64Query(r *http.Request, name string, fallback int64) (int64, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return fallback, nil
	}
	return strconv.ParseInt(raw, 10, 64)
}

func parseIntQuery(r *http.Request, name string, fallback int) (int, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, err
	}
	return value, nil
}
