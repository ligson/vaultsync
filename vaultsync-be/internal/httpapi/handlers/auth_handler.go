package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/ligson/vaultsync/internal/domain"
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
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}

	var (
		session domain.SessionToken
		err     error
	)
	if strings.TrimSpace(req.RefreshToken) != "" {
		session, err = h.service.RefreshByToken(r.Context(), req.RefreshToken)
	} else {
		header := r.Header.Get("Authorization")
		tokenValue, ok := strings.CutPrefix(header, "Bearer ")
		if !ok || tokenValue == "" {
			writeError(w, http.StatusUnauthorized, service.CodeUnauthorized, "请先登录")
			return
		}
		claims, verifyErr := h.service.VerifyToken(tokenValue)
		if verifyErr != nil {
			writeError(w, http.StatusUnauthorized, service.CodeUnauthorized, "登录状态已失效，请重新登录")
			return
		}
		session, err = h.service.Refresh(r.Context(), claims.UserID)
	}
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", session)
}

func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	user, err := h.service.UserByID(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", user)
}

func (h *AuthHandler) StorageUsage(w http.ResponseWriter, r *http.Request) {
	usage, err := h.service.StorageUsage(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", usage)
}

func (h *AuthHandler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Nickname string `json:"nickname"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	user, err := h.service.UpdateProfile(r.Context(), middleware.MustUserID(r.Context()), req.Username, req.Nickname)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "个人资料已更新", user)
}

func (h *AuthHandler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CurrentPassword string `json:"current_password"`
		NewPassword     string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请求内容不是有效 JSON")
		return
	}
	if err := h.service.ChangePassword(r.Context(), middleware.MustUserID(r.Context()), req.CurrentPassword, req.NewPassword); err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "密码已更新", map[string]any{})
}
