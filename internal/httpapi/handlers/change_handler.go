package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/service"
)

type ChangeHandler struct {
	service *service.ChangeService
}

var errInvalidLimit = errors.New("limit must be a positive integer")

func NewChangeHandler(service *service.ChangeService) *ChangeHandler {
	return &ChangeHandler{service: service}
}

func (h *ChangeHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	cursorValue, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	deviceID := r.URL.Query().Get("device_id")
	limit, err := parseChangeLimit(r.URL.Query().Get("limit"))
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, err.Error())
		return
	}
	page, err := h.service.List(r.Context(), userID, deviceID, cursorValue, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errorCodeInternal, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func parseChangeLimit(value string) (int, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, nil
	}
	limit, err := strconv.Atoi(value)
	if err != nil || limit <= 0 {
		return 0, errInvalidLimit
	}
	return limit, nil
}
