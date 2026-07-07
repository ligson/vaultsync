package app

import (
	"encoding/json"
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

func TestAppHealthCheckUsesResponseEnvelope(t *testing.T) {
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

	req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	resp := httptest.NewRecorder()
	application.Handler().ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", resp.Code, resp.Body.String())
	}

	var payload struct {
		Success  bool   `json:"success"`
		Message  string `json:"message"`
		HTTPCode int    `json:"httpCode"`
		Data     struct {
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !payload.Success || payload.Message != "" || payload.HTTPCode != http.StatusOK || payload.Data.Status != "ok" {
		t.Fatalf("unexpected health response: %+v", payload)
	}
}
