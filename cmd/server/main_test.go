package main

import (
	"testing"

	"github.com/ligson/vaultsync/internal/config"
)

func TestLoadConfigRequiresTokenSecret(t *testing.T) {
	t.Setenv("VAULTSYNC_HTTP_ADDR", ":8080")
	t.Setenv("VAULTSYNC_DATA_DIR", t.TempDir())
	t.Setenv("VAULTSYNC_DATABASE_PATH", t.TempDir()+"/vaultsync.db")
	t.Setenv("VAULTSYNC_TOKEN_SECRET", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error when token secret is missing")
	}
}

func TestLoadConfigDefaultsHTTPAddr(t *testing.T) {
	t.Setenv("VAULTSYNC_HTTP_ADDR", "")
	t.Setenv("VAULTSYNC_DATA_DIR", t.TempDir())
	t.Setenv("VAULTSYNC_DATABASE_PATH", t.TempDir()+"/vaultsync.db")
	t.Setenv("VAULTSYNC_TOKEN_SECRET", "secret")

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Fatalf("expected default http addr :8080, got %q", cfg.HTTPAddr)
	}
}

func TestLoadConfigSuccess(t *testing.T) {
	t.Setenv("VAULTSYNC_HTTP_ADDR", "127.0.0.1:9090")
	t.Setenv("VAULTSYNC_DATA_DIR", t.TempDir())
	t.Setenv("VAULTSYNC_DATABASE_PATH", t.TempDir()+"/vaultsync.db")
	t.Setenv("VAULTSYNC_TOKEN_SECRET", "secret")

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.HTTPAddr != "127.0.0.1:9090" {
		t.Fatalf("unexpected http addr %q", cfg.HTTPAddr)
	}
	if cfg.TokenSecret != "secret" {
		t.Fatalf("unexpected token secret %q", cfg.TokenSecret)
	}
	if cfg.DataDir == "" {
		t.Fatal("expected data dir to be set")
	}
	if cfg.DatabasePath == "" {
		t.Fatal("expected database path to be set")
	}
}
