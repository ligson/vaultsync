package app

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/ligson/vaultsync/internal/config"
)

func TestAppExposesHTTPHandler(t *testing.T) {
	dataDir := t.TempDir()
	application, err := New(config.Config{
		HTTPAddr:     "127.0.0.1:0",
		DataDir:      dataDir,
		DatabasePath: filepath.Join(dataDir, "vaultsync.db"),
		TokenSecret:  "test-secret",
	})
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() {
		if err := application.Close(); err != nil {
			t.Fatalf("close app: %v", err)
		}
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/register", nil)
	resp := httptest.NewRecorder()
	application.Handler().ServeHTTP(resp, req)

	if resp.Code == http.StatusNotFound {
		t.Fatal("expected app handler to register api routes")
	}
}
