package app

import "github.com/ligson/vaultsync/internal/config"

type App struct {
	Config config.Config
}

func New(cfg config.Config) (*App, error) {
	return &App{Config: cfg}, nil
}
