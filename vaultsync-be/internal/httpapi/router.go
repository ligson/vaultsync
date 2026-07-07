package httpapi

import (
	"net/http"

	"github.com/ligson/vaultsync/internal/httpapi/handlers"
	"github.com/ligson/vaultsync/internal/httpapi/middleware"
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
	return mux
}

func RegisterRoutes(mux *http.ServeMux, deps Dependencies) {
	mux.HandleFunc("GET /api/v1/health", handlers.Health)
	mux.HandleFunc("POST /api/v1/auth/register", deps.AuthHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", deps.AuthHandler.Login)
	mux.HandleFunc("POST /api/v1/admin/auth/register", deps.AdminHandler.Register)
	mux.HandleFunc("POST /api/v1/admin/auth/login", deps.AdminHandler.Login)

	secured := http.NewServeMux()
	secured.HandleFunc("POST /api/v1/devices", deps.DeviceHandler.Create)
	secured.HandleFunc("GET /api/v1/sync-roots", deps.SyncRootHandler.List)
	secured.HandleFunc("POST /api/v1/sync-roots", deps.SyncRootHandler.Create)
	secured.HandleFunc("POST /api/v1/upload-sessions", deps.UploadHandler.CreateSession)
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
	mux.Handle("/api/v1/devices", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/sync-roots", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/changes", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/objects/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/admin/", middleware.Auth(deps.AuthService, middleware.AdminOnly(deps.AdminService, admin)))
}
