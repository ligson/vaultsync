package app

import (
	"database/sql"
	"net/http"
	"path/filepath"

	"github.com/ligson/vaultsync/internal/config"
	"github.com/ligson/vaultsync/internal/httpapi"
	"github.com/ligson/vaultsync/internal/httpapi/handlers"
	"github.com/ligson/vaultsync/internal/service"
	"github.com/ligson/vaultsync/internal/storage"
	"github.com/ligson/vaultsync/internal/store"
)

type App struct {
	Config          config.Config
	db              *sql.DB
	authService     *service.AuthService
	deviceService   *service.DeviceService
	syncRootService *service.SyncRootService
	uploadService   *service.UploadService
	changeService   *service.ChangeService
	downloadService *service.DownloadService
	deleteService   *service.DeleteService
	adminService    *service.AdminService
}

func New(cfg config.Config) (*App, error) {
	db, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return nil, err
	}

	authRepo := store.NewAuthRepo(db)
	adminRepo := store.NewAdminRepo(db)
	deviceRepo := store.NewDeviceRepo(db)
	syncRootRepo := store.NewSyncRootRepo(db)
	objectRepo := store.NewObjectRepo(db)
	fsStorage := storage.NewFSStorage(cfg.DataDir)
	adminService := service.NewAdminService(adminRepo, cfg.AdminRegistrationEnabled, cfg.DefaultUserQuotaBytes, cfg.DataDir)
	adminService.SetRuntimePaths(cfg.HTTPAddr, cfg.DatabasePath)
	return &App{
		Config: cfg,
		db:     db,
		authService: service.NewAuthService(authRepo, cfg.TokenSecret, service.AuthOptions{
			AdminRegistrationEnabled: cfg.AdminRegistrationEnabled,
			DefaultUserQuotaBytes:    cfg.DefaultUserQuotaBytes,
		}),
		deviceService:   service.NewDeviceService(deviceRepo),
		syncRootService: service.NewSyncRootService(syncRootRepo, deviceRepo),
		uploadService:   service.NewUploadService(objectRepo, deviceRepo, syncRootRepo, fsStorage),
		changeService:   service.NewChangeService(db, deviceRepo, cfg.DataDir),
		downloadService: service.NewDownloadService(db, cfg.DataDir),
		deleteService:   service.NewDeleteService(db, deviceRepo, syncRootRepo),
		adminService:    adminService,
	}, nil
}

func (a *App) Dependencies() httpapi.Dependencies {
	return httpapi.Dependencies{
		AuthHandler:     handlers.NewAuthHandler(a.authService),
		DeviceHandler:   handlers.NewDeviceHandler(a.deviceService),
		SyncRootHandler: handlers.NewSyncRootHandler(a.syncRootService),
		UploadHandler:   handlers.NewUploadHandler(a.uploadService),
		ChangeHandler:   handlers.NewChangeHandler(a.changeService),
		DownloadHandler: handlers.NewDownloadHandler(a.downloadService),
		DeleteHandler:   handlers.NewDeleteHandler(a.deleteService),
		AdminHandler:    handlers.NewAdminHandler(a.authService, a.adminService),
		AuthService:     a.authService,
		AdminService:    a.adminService,
		DownloadDir:     filepath.Join(a.Config.DataDir, "downloads"),
	}
}

func (a *App) Handler() http.Handler {
	return httpapi.NewRouter(a.Dependencies())
}

func (a *App) DB() *sql.DB {
	return a.db
}

func (a *App) Close() error {
	if a.db == nil {
		return nil
	}
	return a.db.Close()
}
