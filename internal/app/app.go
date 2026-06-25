package app

import (
	"database/sql"

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
		syncRootService: service.NewSyncRootService(syncRootRepo),
		uploadService:   service.NewUploadService(objectRepo, fsStorage),
	}, nil
}

func (a *App) Dependencies() httpapi.Dependencies {
	return httpapi.Dependencies{
		AuthHandler:     handlers.NewAuthHandler(a.authService),
		DeviceHandler:   handlers.NewDeviceHandler(a.deviceService),
		SyncRootHandler: handlers.NewSyncRootHandler(a.syncRootService),
		UploadHandler:   handlers.NewUploadHandler(a.uploadService),
		AuthService:     a.authService,
	}
}

func (a *App) Close() error {
	if a.db == nil {
		return nil
	}
	return a.db.Close()
}
