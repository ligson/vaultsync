package integration

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestUploadCiphertextAndCompleteVersion(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)

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
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	sessionID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte(" world"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
}

func TestUploadSessionRejectsForeignSyncRoot(t *testing.T) {
	app := testutil.NewTestServer(t)
	aliceToken := registerAndLogin(t, app, "alice@example.com")
	bobToken := registerAndLogin(t, app, "bob@example.com")

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, aliceToken)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	aliceDeviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:alice-path","cleanup_policy":"delete","archive_path":""}`, aliceDeviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, aliceToken)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	aliceRootID := testutil.MustReadJSONField(t, resp, "id")

	createBody := fmt.Sprintf(`{
		"device_id":"%s",
		"sync_root_id":"%s",
		"object_id":"obj-foreign",
		"version_id":"ver-foreign",
		"total_size":4,
		"chunk_size":4,
		"encrypted_name":"enc:foreign.txt",
		"metadata_json":"{}"
	}`, aliceDeviceID, aliceRootID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, bobToken)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
}

func TestUploadRejectsChunksBeyondTotalSize(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	sessionID := createUploadSession(t, app, token, deviceID, rootID, "obj-too-large", "ver-too-large", 4)

	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	testutil.AssertJSONErrorCode(t, resp, "invalid_request")
}

func TestCompleteRejectsIncompleteUpload(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	sessionID := createUploadSession(t, app, token, deviceID, rootID, "obj-incomplete", "ver-incomplete", 5)

	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hi"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
}

func TestUploadRejectsChunkAfterComplete(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	sessionID := createUploadSession(t, app, token, deviceID, rootID, "obj-completed", "ver-completed", 4)

	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("done"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte("again"), token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
}

func TestListChangesAndDownloadCiphertext(t *testing.T) {
	app, token, versionID := testutil.NewUploadedVersionServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, versionID)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/objects/"+versionID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertHeader(t, resp, "Content-Type", "application/octet-stream")
}

func TestDownloadRejectsForeignVersion(t *testing.T) {
	app, _, versionID := testutil.NewUploadedVersionServer(t)
	bobToken := registerAndLogin(t, app, "bob@example.com")

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/objects/"+versionID, "", bobToken)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	testutil.AssertJSONErrorCode(t, resp, "invalid_request")
}

func createUploadSession(t *testing.T, app *httptest.Server, token, deviceID, rootID, objectID, versionID string, totalSize int64) string {
	t.Helper()
	createBody := fmt.Sprintf(`{
		"device_id":"%s",
		"sync_root_id":"%s",
		"object_id":"%s",
		"version_id":"%s",
		"total_size":%d,
		"chunk_size":4,
		"encrypted_name":"enc:%s.txt",
		"metadata_json":"{}"
	}`, deviceID, rootID, objectID, versionID, totalSize, objectID)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	return testutil.MustReadJSONField(t, resp, "id")
}
