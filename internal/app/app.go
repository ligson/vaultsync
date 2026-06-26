package app

import (
	"database/sql"
	"net/http"

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
}

func New(cfg config.Config) (*App, error) {
	db, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return nil, err
	}

	authRepo := store.NewAuthRepo(db)
	deviceRepo := store.NewDeviceRepo(db)
	syncRootRepo := store.NewSyncRootRepo(db)
	objectRepo := store.NewObjectRepo(db)
	fsStorage := storage.NewFSStorage(cfg.DataDir)
	return &App{
		Config:          cfg,
		db:              db,
		authService:     service.NewAuthService(authRepo, cfg.TokenSecret),
		deviceService:   service.NewDeviceService(deviceRepo),
		syncRootService: service.NewSyncRootService(syncRootRepo, deviceRepo),
		uploadService:   service.NewUploadService(objectRepo, deviceRepo, syncRootRepo, fsStorage),
		changeService:   service.NewChangeService(db, cfg.DataDir),
		downloadService: service.NewDownloadService(db, cfg.DataDir),
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
		AuthService:     a.authService,
	}
}

func (a *App) Handler() http.Handler {
	return httpapi.NewRouter(a.Dependencies())
}

func (a *App) Close() error {
	if a.db == nil {
		return nil
	}
	return a.db.Close()
}
