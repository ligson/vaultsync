package handlers

import (
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/service"
)

type DeleteHandler struct {
	service *service.DeleteService
}

func NewDeleteHandler(service *service.DeleteService) *DeleteHandler {
	return &DeleteHandler{service: service}
}

func (h *DeleteHandler) DeleteObject(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	objectID := r.PathValue("objectID")
	deviceID := r.URL.Query().Get("device_id")
	syncRootID := r.URL.Query().Get("sync_root_id")
	result, err := h.service.DeleteObject(r.Context(), userID, deviceID, syncRootID, objectID)
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, result)
}
