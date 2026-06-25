package testutil

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func NewUploadReadyServer(t *testing.T) (*httptest.Server, string, string, string) {
	t.Helper()

	app, token := NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	deviceID := MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"delete","archive_path":""}`, deviceID)
	resp = JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	rootID := MustReadJSONField(t, resp, "id")

	return app, token, deviceID, rootID
}
