package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type AuthHandler struct {
	service *service.AuthService
}

func NewAuthHandler(service *service.AuthService) *AuthHandler {
	return &AuthHandler{service: service}
}

func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}

	user, err := h.service.Register(r.Context(), req.Email, req.Password)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusCreated, "", map[string]string{"id": user.ID, "email": user.Email})
}

func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}

	session, err := h.service.Login(r.Context(), req.Email, req.Password)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", session)
}

func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	session, err := h.service.Refresh(r.Context(), userID)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", session)
}
