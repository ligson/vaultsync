package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/service"
)

type UploadHandler struct {
	service *service.UploadService
}

func NewUploadHandler(service *service.UploadService) *UploadHandler {
	return &UploadHandler{service: service}
}

func (h *UploadHandler) CreateSession(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	var req struct {
		DeviceID      string `json:"device_id"`
		SyncRootID    string `json:"sync_root_id"`
		ObjectID      string `json:"object_id"`
		VersionID     string `json:"version_id"`
		TotalSize     int64  `json:"total_size"`
		ChunkSize     int64  `json:"chunk_size"`
		EncryptedName string `json:"encrypted_name"`
		MetadataJSON  string `json:"metadata_json"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}

	session, err := h.service.CreateSession(r.Context(), userID, req.DeviceID, req.SyncRootID, req.ObjectID, req.VersionID, req.EncryptedName, req.MetadataJSON, req.TotalSize, req.ChunkSize)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, session)
}

func (h *UploadHandler) UploadPart(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	sessionID := r.PathValue("sessionID")
	if err := h.service.AppendChunk(r.Context(), userID, sessionID, r.Body); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *UploadHandler) Complete(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	sessionID := r.PathValue("sessionID")
	version, err := h.service.Complete(r.Context(), userID, sessionID)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, version)
}
