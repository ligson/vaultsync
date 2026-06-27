package handlers

import (
	"io"
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/service"
)

type DownloadHandler struct {
	service *service.DownloadService
}

func NewDownloadHandler(service *service.DownloadService) *DownloadHandler {
	return &DownloadHandler{service: service}
}

func (h *DownloadHandler) Download(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	versionID := r.PathValue("versionID")
	reader, err := h.service.OpenCiphertext(r.Context(), userID, versionID)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	defer reader.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = io.Copy(w, reader)
}
