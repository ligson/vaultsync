package handlers

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"strconv"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type DocumentHandler struct {
	service *service.DocumentService
}

func NewDocumentHandler(service *service.DocumentService) *DocumentHandler {
	return &DocumentHandler{service: service}
}

func (h *DocumentHandler) Overview(w http.ResponseWriter, r *http.Request) {
	data, err := h.service.Overview(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *DocumentHandler) Bookshelf(w http.ResponseWriter, r *http.Request) {
	data, err := h.service.Bookshelf(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{"items": data, "limit": 100})
}

func (h *DocumentHandler) UpdateBookshelf(w http.ResponseWriter, r *http.Request) {
	var request struct {
		SectionID string  `json:"section_id"`
		Offset    int64   `json:"offset"`
		Progress  float64 `json:"progress"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	data, err := h.service.UpdateBookshelf(r.Context(), middleware.MustUserID(r.Context()),
		r.PathValue("documentID"), request.SectionID, request.Offset, request.Progress)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *DocumentHandler) DeleteBookshelf(w http.ResponseWriter, r *http.Request) {
	if err := h.service.DeleteBookshelf(r.Context(), middleware.MustUserID(r.Context()), r.PathValue("documentID")); err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{})
}

func (h *DocumentHandler) Items(w http.ResponseWriter, r *http.Request) {
	limit, cursor := 60, 0
	var err error
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "分页大小不正确")
			return
		}
	}
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		cursor, err = strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "分页游标不正确")
			return
		}
	}
	data, err := h.service.Items(r.Context(), middleware.MustUserID(r.Context()),
		limit, cursor, r.URL.Query().Get("type"), r.URL.Query().Get("device_id"),
		r.URL.Query().Get("sort"), r.URL.Query().Get("order"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *DocumentHandler) Candidates(w http.ResponseWriter, r *http.Request) {
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

func (h *DocumentHandler) PlainBackfill(w http.ResponseWriter, r *http.Request) {
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
	data, err := h.service.BackfillPlain(r.Context(), middleware.MustUserID(r.Context()), cursor, limit)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *DocumentHandler) Preview(w http.ResponseWriter, r *http.Request) {
	mode := r.URL.Query().Get("mode")
	if mode == "" {
		data, err := h.service.Preview(r.Context(), middleware.MustUserID(r.Context()), r.PathValue("documentID"))
		if err != nil {
			writeServiceError(w, err)
			return
		}
		response.Write(w, http.StatusOK, "", data)
		return
	}
	offset := int64(0)
	limit := 0
	var err error
	if raw := r.URL.Query().Get("offset"); raw != "" {
		offset, err = strconv.ParseInt(raw, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "预览偏移量不正确")
			return
		}
	}
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "预览分页大小不正确")
			return
		}
	}
	data, err := h.service.PreviewPage(r.Context(), middleware.MustUserID(r.Context()),
		r.PathValue("documentID"), mode, r.URL.Query().Get("section_id"), offset, limit)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}

func (h *DocumentHandler) Content(w http.ResponseWriter, r *http.Request) {
	file, contentType, err := h.service.OpenPreviewContent(r.Context(), middleware.MustUserID(r.Context()), r.PathValue("documentID"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Cache-Control", "private, max-age=300")
	info, err := file.Stat()
	if err != nil {
		writeServiceError(w, err)
		return
	}
	http.ServeContent(w, r, filepath.Base(info.Name()), info.ModTime(), file)
}

func (h *DocumentHandler) Backfill(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Items             []domain.DocumentBackfillInput `json:"items"`
		IgnoredVersionIDs []string                       `json:"ignored_version_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	data, err := h.service.Backfill(r.Context(), middleware.MustUserID(r.Context()),
		request.Items, request.IgnoredVersionIDs)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", data)
}
