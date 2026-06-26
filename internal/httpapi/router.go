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
	AuthService     middleware.TokenVerifier
}

func NewRouter(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	return mux
}

func RegisterRoutes(mux *http.ServeMux, deps Dependencies) {
	mux.HandleFunc("POST /api/v1/auth/register", deps.AuthHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", deps.AuthHandler.Login)

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
	mux.Handle("/api/v1/devices", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/sync-roots", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/upload-sessions/", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/changes", middleware.Auth(deps.AuthService, secured))
	mux.Handle("/api/v1/objects/", middleware.Auth(deps.AuthService, secured))
}
