package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ligson/vaultsync/internal/config"
)

func TestLoadConfigFileRequiresTokenSecret(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	writeConfigFile(t, configPath, `
app:
  server:
    http_addr: ":8080"
  storage:
    data_dir: "./data"
    database_path: "./data/vaultsync.db"
  security:
    token_secret: ""
`)

	_, err := config.LoadFile(configPath)
	if err == nil {
		t.Fatal("expected error when token secret is missing")
	}
	if !strings.Contains(err.Error(), "app.security.token_secret") {
		t.Fatalf("expected token secret error, got %v", err)
	}
}

func TestLoadConfigFileDefaultsHTTPAddr(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	writeConfigFile(t, configPath, `
app:
  storage:
    data_dir: "./data"
    database_path: "./data/vaultsync.db"
  security:
    token_secret: "secret"
`)

	cfg, err := config.LoadFile(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.HTTPAddr != ":8080" {
		t.Fatalf("expected default http addr :8080, got %q", cfg.HTTPAddr)
	}
}

func TestLoadConfigFileSuccess(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	writeConfigFile(t, configPath, `
app:
  server:
    http_addr: "127.0.0.1:9090"
  storage:
    data_dir: "/nas/vaultsync/data"
    database_path: "/nas/vaultsync/data/vaultsync.db"
  security:
    token_secret: "secret"
  admin:
    registration_enabled: true
    default_user_quota_bytes: 2147483648
`)

	cfg, err := config.LoadFile(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.HTTPAddr != "127.0.0.1:9090" {
		t.Fatalf("unexpected http addr %q", cfg.HTTPAddr)
	}
	if cfg.TokenSecret != "secret" {
		t.Fatalf("unexpected token secret %q", cfg.TokenSecret)
	}
	if cfg.DataDir != "/nas/vaultsync/data" {
		t.Fatalf("unexpected data dir %q", cfg.DataDir)
	}
	if cfg.DatabasePath != "/nas/vaultsync/data/vaultsync.db" {
		t.Fatalf("unexpected database path %q", cfg.DatabasePath)
	}
	if !cfg.AdminRegistrationEnabled {
		t.Fatal("expected admin registration to be enabled")
	}
	if cfg.DefaultUserQuotaBytes != 2147483648 {
		t.Fatalf("unexpected default quota %d", cfg.DefaultUserQuotaBytes)
	}
}

func TestLoadConfigFileDefaultsStoragePaths(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	writeConfigFile(t, configPath, `
app:
  security:
    token_secret: "secret"
`)

	cfg, err := config.LoadFile(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.DataDir != "./data" {
		t.Fatalf("unexpected data dir %q", cfg.DataDir)
	}
	if cfg.DatabasePath != "data/vaultsync.db" {
		t.Fatalf("unexpected database path %q", cfg.DatabasePath)
	}
}

func writeConfigFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.TrimSpace(content)+"\n"), 0o644); err != nil {
		t.Fatalf("write config file: %v", err)
	}
}
