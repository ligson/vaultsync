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

func NewUploadedVersionServer(t *testing.T) (*httptest.Server, string, string) {
	t.Helper()

	app, token, deviceID, rootID := NewUploadReadyServer(t)
	createBody := fmt.Sprintf(`{
		"device_id":"%s",
		"sync_root_id":"%s",
		"object_id":"obj-1",
		"version_id":"ver-1",
		"total_size":11,
		"chunk_size":5,
		"encrypted_name":"enc:file.txt",
		"metadata_json":"{\"nonce\":\"abc\"}"
	}`, deviceID, rootID)
	resp := JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	sessionID := MustReadJSONField(t, resp, "id")

	resp = BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	AssertStatus(t, resp, http.StatusNoContent)
	resp = BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte(" world"), token)
	AssertStatus(t, resp, http.StatusNoContent)
	resp = JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	AssertStatus(t, resp, http.StatusCreated)
	return app, token, "ver-1"
}
