package testutil

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/ligson/vaultsync/internal/app"
	"github.com/ligson/vaultsync/internal/config"
	"github.com/ligson/vaultsync/internal/httpapi"
)

func NewTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	dataDir := t.TempDir()
	instance, err := app.New(config.Config{
		HTTPAddr:     "127.0.0.1:0",
		DataDir:      dataDir,
		DatabasePath: filepath.Join(dataDir, "vaultsync.db"),
		TokenSecret:  "test-secret",
	})
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() {
		if err := instance.Close(); err != nil {
			t.Fatalf("close app: %v", err)
		}
	})
	server := httptest.NewServer(httpapi.NewRouter(instance.Dependencies()))
	t.Cleanup(server.Close)
	return server
}

func NewAuthenticatedServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()

	server := NewTestServer(t)
	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := JSONRequest(t, server, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	AssertStatus(t, resp, http.StatusCreated)

	loginBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp = JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	AssertStatus(t, resp, http.StatusOK)
	token := MustReadJSONField(t, resp, "token")
	return server, token
}
