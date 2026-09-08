package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type MediaHandler struct {
	service *service.MediaService
}

func NewMediaHandler(service *service.MediaService) *MediaHandler {
	return &MediaHandler{service: service}
}

func (h *MediaHandler) Months(w http.ResponseWriter, r *http.Request) {
	data, err := h.service.Months(r.Context(), middleware.MustUserID(r.Context()),
		r.URL.Query().Get("type"), r.URL.Query().Get("device_id"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *MediaHandler) Items(w http.ResponseWriter, r *http.Request) {
	year, yearErr := strconv.Atoi(r.URL.Query().Get("year"))
	month, monthErr := strconv.Atoi(r.URL.Query().Get("month"))
	limit := 60
	if value := r.URL.Query().Get("limit"); value != "" {
		var err error
		limit, err = strconv.Atoi(value)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "分页大小不正确")
			return
		}
	}
	if yearErr != nil || monthErr != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "年月参数不正确")
		return
	}
	data, err := h.service.Items(r.Context(), middleware.MustUserID(r.Context()),
		year, month, limit, r.URL.Query().Get("type"),
		r.URL.Query().Get("device_id"), r.URL.Query().Get("cursor"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *MediaHandler) Candidates(w http.ResponseWriter, r *http.Request) {
	cursor := int64(0)
	limit := 0
	var err error
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		cursor, err = strconv.ParseInt(raw, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "游标参数不正确")
			return
		}
	}
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "分页大小参数不正确")
			return
		}
	}
	data, err := h.service.Candidates(r.Context(), middleware.MustUserID(r.Context()), cursor, limit)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *MediaHandler) Backfill(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Items []domain.MediaBackfillInput `json:"items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	data, err := h.service.Backfill(r.Context(), middleware.MustUserID(r.Context()), request.Items)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *MediaHandler) PutThumbnail(w http.ResponseWriter, r *http.Request) {
	err := h.service.PutThumbnail(r.Context(), middleware.MustUserID(r.Context()),
		r.PathValue("mediaID"), r.Body)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *MediaHandler) GetThumbnail(w http.ResponseWriter, r *http.Request) {
	file, err := h.service.OpenThumbnail(r.Context(), middleware.MustUserID(r.Context()),
		r.PathValue("mediaID"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	_, _ = io.Copy(w, file)
}
