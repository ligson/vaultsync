package app

import (
	"database/sql"

	"github.com/ligson/vaultsync/internal/config"
	"github.com/ligson/vaultsync/internal/httpapi"
	"github.com/ligson/vaultsync/internal/httpapi/handlers"
	"github.com/ligson/vaultsync/internal/service"
	"github.com/ligson/vaultsync/internal/store"
)

type App struct {
	Config      config.Config
	db          *sql.DB
	authService *service.AuthService
}

func New(cfg config.Config) (*App, error) {
	db, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return nil, err
	}

	authRepo := store.NewAuthRepo(db)
	return &App{
		Config:      cfg,
		db:          db,
		authService: service.NewAuthService(authRepo, cfg.TokenSecret),
	}, nil
}

func (a *App) Dependencies() httpapi.Dependencies {
	return httpapi.Dependencies{
		AuthHandler: handlers.NewAuthHandler(a.authService),
	}
}

func (a *App) Close() error {
	if a.db == nil {
		return nil
	}
	return a.db.Close()
}
