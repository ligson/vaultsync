package handlers

import (
	"io"
	"net/http"
	"strconv"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type AvatarHandler struct {
	service *service.AvatarService
}

func NewAvatarHandler(service *service.AvatarService) *AvatarHandler {
	return &AvatarHandler{service: service}
}

func (h *AvatarHandler) Get(w http.ResponseWriter, r *http.Request) {
	file, avatar, err := h.service.Open(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(avatar.SizeBytes, 10))
	w.Header().Set("ETag", `"`+avatar.ContentHash+`"`)
	_, _ = io.Copy(w, file)
}

func (h *AvatarHandler) Put(w http.ResponseWriter, r *http.Request) {
	avatar, err := h.service.Save(r.Context(), middleware.MustUserID(r.Context()), r.Body)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "头像已更新", avatar)
}
