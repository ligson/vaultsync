package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type DeviceHandler struct {
	service *service.DeviceService
}

func NewDeviceHandler(service *service.DeviceService) *DeviceHandler {
	return &DeviceHandler{service: service}
}

func (h *DeviceHandler) Create(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	var req struct {
		Name     string `json:"name"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}

	device, err := h.service.Register(r.Context(), userID, req.Name, req.Platform)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusCreated, "", device)
}
