package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
	"github.com/ligson/vaultsync/internal/service"
)

type AdminHandler struct {
	authService  *service.AuthService
	adminService *service.AdminService
}

func NewAdminHandler(authService *service.AuthService, adminService *service.AdminService) *AdminHandler {
	return &AdminHandler{authService: authService, adminService: adminService}
}

func (h *AdminHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	user, err := h.authService.RegisterAdmin(r.Context(), req.Email, req.Password)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusCreated, "", map[string]any{
		"id":    user.ID,
		"email": user.Email,
		"role":  user.Role,
	})
}

func (h *AdminHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	session, err := h.authService.LoginAdmin(r.Context(), req.Email, req.Password)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", session)
}

func (h *AdminHandler) Me(w http.ResponseWriter, r *http.Request) {
	user, err := h.authService.UserByID(r.Context(), middleware.MustUserID(r.Context()))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", user)
}

func (h *AdminHandler) Overview(w http.ResponseWriter, r *http.Request) {
	overview, err := h.adminService.Overview(r.Context())
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", overview)
}

func (h *AdminHandler) Users(w http.ResponseWriter, r *http.Request) {
	users, err := h.adminService.Users(r.Context())
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{"items": users})
}

func (h *AdminHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email      string `json:"email"`
		Password   string `json:"password"`
		QuotaBytes int64  `json:"quota_bytes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	user, err := h.authService.RegisterUserWithQuota(r.Context(), req.Email, req.Password, req.QuotaBytes)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.user.create", map[string]any{
		"target_user_id": user.ID,
		"email":          user.Email,
		"quota_bytes":    user.QuotaBytes,
	})
	response.Write(w, http.StatusCreated, "用户已创建", user)
}

func (h *AdminHandler) UpdateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Status     string `json:"status"`
		QuotaBytes int64  `json:"quota_bytes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	user, err := h.adminService.UpdateUser(r.Context(), r.PathValue("userID"), req.Status, req.QuotaBytes)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.user.update", map[string]any{
		"target_user_id": user.ID,
		"status":         user.Status,
		"quota_bytes":    user.QuotaBytes,
	})
	response.Write(w, http.StatusOK, "", user)
}

func (h *AdminHandler) ResetUserPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	if err := h.authService.ResetPassword(r.Context(), r.PathValue("userID"), req.Password); err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.user.reset_password", map[string]any{
		"target_user_id": r.PathValue("userID"),
	})
	response.Write(w, http.StatusOK, "用户密码已重置", map[string]any{})
}

func (h *AdminHandler) Settings(w http.ResponseWriter, r *http.Request) {
	settings, err := h.adminService.Settings(r.Context())
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", settings)
}

func (h *AdminHandler) UpdateSettings(w http.ResponseWriter, r *http.Request) {
	var req map[string]any
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	settings, err := h.adminService.UpdateSettings(r.Context(), req)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.settings.update", map[string]any{
		"values": req,
	})
	response.Write(w, http.StatusOK, "", settings)
}

func (h *AdminHandler) Downloads(w http.ResponseWriter, r *http.Request) {
	releases, err := h.adminService.Downloads(r.Context())
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{"items": releases})
}

func (h *AdminHandler) UpdateDownload(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FileName    string `json:"file_name"`
		Version     string `json:"version"`
		DownloadURL string `json:"download_url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "invalid json")
		return
	}
	release, err := h.adminService.UpdateDownload(r.Context(), r.PathValue("platform"), domain.DownloadRelease{
		FileName:    req.FileName,
		Version:     req.Version,
		DownloadURL: req.DownloadURL,
	})
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.download.update", map[string]any{
		"platform":     release.Platform,
		"file_name":    release.FileName,
		"version":      release.Version,
		"download_url": release.DownloadURL,
	})
	response.Write(w, http.StatusOK, "", release)
}

func (h *AdminHandler) UploadDownload(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(256 << 20); err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "上传表单无效")
		return
	}
	version := r.FormValue("version")
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "请选择要上传的安装包文件")
		return
	}
	defer file.Close()
	release, err := h.adminService.UploadDownload(r.Context(), r.PathValue("platform"), version, header.Filename, file)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.download.upload", map[string]any{
		"platform":     release.Platform,
		"file_name":    release.FileName,
		"version":      release.Version,
		"download_url": release.DownloadURL,
	})
	response.Write(w, http.StatusCreated, "新版本已上传", release)
}

func (h *AdminHandler) DeleteDownloadFile(w http.ResponseWriter, r *http.Request) {
	release, err := h.adminService.DeleteDownloadFile(r.Context(), r.PathValue("platform"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	_ = h.adminService.RecordAudit(r.Context(), middleware.MustUserID(r.Context()), "admin.download.delete_file", map[string]any{
		"platform":  release.Platform,
		"file_name": release.FileName,
	})
	response.Write(w, http.StatusOK, "安装包文件已删除", map[string]any{})
}

func (h *AdminHandler) AuditLogs(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, errorCodeInvalidRequest, "limit 必须是数字")
			return
		}
		limit = parsed
	}
	logs, err := h.adminService.AuditLogs(r.Context(), limit)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", map[string]any{"items": logs})
}

func (h *AdminHandler) SystemStatus(w http.ResponseWriter, r *http.Request) {
	status, err := h.adminService.SystemStatus(r.Context())
	if err != nil {
		writeServiceError(w, err)
		return
	}
	response.Write(w, http.StatusOK, "", status)
}
