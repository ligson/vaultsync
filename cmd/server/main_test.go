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
