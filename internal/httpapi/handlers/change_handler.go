package handlers

import (
	"net/http"
	"strconv"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/service"
)

type ChangeHandler struct {
	service *service.ChangeService
}

func NewChangeHandler(service *service.ChangeService) *ChangeHandler {
	return &ChangeHandler{service: service}
}

func (h *ChangeHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	cursorValue, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	items, nextCursor, err := h.service.List(r.Context(), userID, cursorValue)
	if err != nil {
		writeError(w, http.StatusInternalServerError, errorCodeInternal, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items":       items,
		"next_cursor": nextCursor,
	})
}
