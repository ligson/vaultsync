package httpapi

import (
	"net/http"
	"strings"

	"github.com/ligson/vaultsync/internal/httpapi/handlers"
	"github.com/ligson/vaultsync/internal/httpapi/middleware"
	"github.com/ligson/vaultsync/internal/httpapi/response"
)

type Dependencies struct {
	AuthHandler     *handlers.AuthHandler
	DeviceHandler   *handlers.DeviceHandler
	SyncRootHandler *handlers.SyncRootHandler
	UploadHandler   *handlers.UploadHandler
	ChangeHandler   *handlers.ChangeHandler
	DownloadHandler *handlers.DownloadHandler
	DeleteHandler   *handlers.DeleteHandler
	AdminHandler    *handlers.AdminHandler
	AuthService     middleware.TokenVerifier
	AdminService    middleware.AdminAuthorizer
	DownloadDir     string
}

func NewRouter(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	return apiJSONFallback(mux)
}

func RegisterRoutes(mux *http.ServeMux, deps Dependencies) {
	mux.HandleFunc("GET /api/v1/health", handlers.Health)
	mux.HandleFunc("POST /api/v1/auth/register", deps.AuthHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", deps.AuthHandler.Login)
	mux.HandleFunc("POST /api/v1/admin/auth/register", deps.AdminHandler.Register)
	mux.HandleFunc("POST /api/v1/admin/auth/login", deps.AdminHandler.Login)
	mux.HandleFunc("GET /api/v1/releases/{platform}", deps.AdminHandler.DownloadRelease)

	secured := http.NewServeMux()
	secured.HandleFunc("POST /api/v1/auth/refresh", deps.AuthHandler.Refresh)
	secured.HandleFunc("GET /api/v1/auth/me", deps.AuthHandler.Me)
	secured.HandleFunc("GET /api/v1/auth/storage-usage", deps.AuthHandler.StorageUsage)
	secured.HandleFunc("PATCH /api/v1/auth/me", deps.AuthHandler.UpdateMe)
	secured.HandleFunc("POST /api/v1/auth/change-password", deps.AuthHandler.ChangePassword)
	secured.HandleFunc("POST /api/v1/devices", deps.DeviceHandler.Create)
	secured.HandleFunc("GET /api/v1/sync-roots", deps.SyncRootHandler.List)
	secured.HandleFunc("POST /api/v1/sync-roots", deps.SyncRootHandler.Create)
	secured.HandleFunc("PATCH /api/v1/sync-roots/{syncRootID}", deps.SyncRootHandler.UpdateCleanupPolicy)
	secured.HandleFunc("DELETE /api/v1/sync-roots/{syncRootID}", deps.SyncRootHandler.Delete)
	secured.HandleFunc("GET /api/v1/sync-roots/{syncRootID}/remote-objects", deps.SyncRootHandler.ListRemoteBackupObjects)
	secured.HandleFunc("POST /api/v1/upload-sessions", deps.UploadHandler.CreateSession)
	secured.HandleFunc("GET /api/v1/upload-sessions/{sessionID}", deps.UploadHandler.GetSession)
	secured.HandleFunc("PUT /api/v1/upload-sessions/{sessionID}/parts/{partIndex}", deps.UploadHandler.UploadPart)
	secured.HandleFunc("POST /api/v1/upload-sessions/{sessionID}/complete", deps.UploadHandler.Complete)
	secured.HandleFunc("GET /api/v1/changes", deps.ChangeHandler.List)
	secured.HandleFunc("GET /api/v1/objects/{versionID}", deps.DownloadHandler.Download)
	secured.HandleFunc("DELETE /api/v1/objects/{objectID}", deps.DeleteHandler.DeleteObject)

	admin := http.NewServeMux()
	admin.HandleFunc("GET /api/v1/admin/me", deps.AdminHandler.Me)
	admin.HandleFunc("GET /api/v1/admin/overview", deps.AdminHandler.Overview)
	admin.HandleFunc("GET /api/v1/admin/audit-logs", deps.AdminHandler.AuditLogs)
	admin.HandleFunc("GET /api/v1/admin/system/status", deps.AdminHandler.SystemStatus)
	admin.HandleFunc("GET /api/v1/admin/users", deps.AdminHandler.Users)
	admin.HandleFunc("POST /api/v1/admin/users", deps.AdminHandler.CreateUser)
	admin.HandleFunc("PATCH /api/v1/admin/users/{userID}", deps.AdminHandler.UpdateUser)
	admin.HandleFunc("POST /api/v1/admin/users/{userID}/reset-password", deps.AdminHandler.ResetUserPassword)
	admin.HandleFunc("GET /api/v1/admin/settings", deps.AdminHandler.Settings)
	admin.HandleFunc("PUT /api/v1/admin/settings", deps.AdminHandler.UpdateSettings)
	admin.HandleFunc("GET /api/v1/admin/downloads", deps.AdminHandler.Downloads)
	admin.HandleFunc("PUT /api/v1/admin/downloads/{platform}", deps.AdminHandler.UpdateDownload)
	admin.HandleFunc("POST /api/v1/admin/downloads/{platform}/upload", deps.AdminHandler.UploadDownload)
	admin.HandleFunc("DELETE /api/v1/admin/downloads/{platform}/file", deps.AdminHandler.DeleteDownloadFile)
	mux.Handle("/downloads/", http.StripPrefix("/downloads/", http.FileServer(http.Dir(deps.DownloadDir))))
	mux.Handle("/api/v1/auth/refresh", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/auth/me", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/auth/storage-usage", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/auth/change-password", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/devices", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/sync-roots", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/sync-roots/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/changes", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/objects/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/admin/", middleware.Auth(deps.AuthService, middleware.AdminOnly(deps.AdminService, admin)))
}

type apiFallbackWriter struct {
	http.ResponseWriter
	path        string
	status      int
	intercepted bool
}

func apiJSONFallback(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/v1/") {
			next.ServeHTTP(w, r)
			return
		}
		writer := &apiFallbackWriter{ResponseWriter: w, path: r.URL.Path}
		next.ServeHTTP(writer, r)
		if writer.intercepted {
			status := writer.status
			message := "接口不存在"
			code := "not_found"
			if status == http.StatusMethodNotAllowed {
				message = "当前接口不支持这个请求方式"
				code = "method_not_allowed"
			}
			response.Write(w, status, message, map[string]any{"code": code})
		}
	})
}

func (w *apiFallbackWriter) WriteHeader(status int) {
	w.status = status
	if (status == http.StatusNotFound || status == http.StatusMethodNotAllowed) && !strings.Contains(w.Header().Get("Content-Type"), "application/json") {
		w.intercepted = true
		return
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *apiFallbackWriter) Write(payload []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if w.intercepted {
		return len(payload), nil
	}
	return w.ResponseWriter.Write(payload)
}
