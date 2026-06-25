package config

import (
	"errors"
	"os"
)

type Config struct {
	HTTPAddr     string
	DataDir      string
	DatabasePath string
	TokenSecret  string
}

func Load() (Config, error) {
	cfg := Config{
		HTTPAddr:     valueOrDefault("VAULTSYNC_HTTP_ADDR", ":8080"),
		DataDir:      os.Getenv("VAULTSYNC_DATA_DIR"),
		DatabasePath: os.Getenv("VAULTSYNC_DATABASE_PATH"),
		TokenSecret:  os.Getenv("VAULTSYNC_TOKEN_SECRET"),
	}

	if cfg.DataDir == "" {
		return Config{}, errors.New("VAULTSYNC_DATA_DIR is required")
	}
	if cfg.DatabasePath == "" {
		return Config{}, errors.New("VAULTSYNC_DATABASE_PATH is required")
	}
	if cfg.TokenSecret == "" {
		return Config{}, errors.New("VAULTSYNC_TOKEN_SECRET is required")
	}

	return cfg, nil
}

func valueOrDefault(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
