package integration

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestChangesCursorIsScopedByDevice(t *testing.T) {
	instance, app := testutil.NewTestAppAndServer(t)
	token := registerAndLogin(t, app, "alice@example.com")

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", `{"name":"Alice MacBook","platform":"macos"}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceAID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", `{"name":"Alice iPhone","platform":"ios"}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceBID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"keep","archive_path":""}`, deviceAID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	rootID := testutil.MustReadJSONField(t, resp, "id")

	sessionID := createUploadSession(t, app, token, deviceAID, rootID, "obj-device-cursor", "ver-device-cursor", 4)
	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("data"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0&device_id="+deviceAID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, "ver-device-cursor")

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0&device_id="+deviceBID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, "ver-device-cursor")

	var cursorRows int
	err := instance.DB().QueryRow(`
		SELECT COUNT(*)
		FROM sync_cursors
		WHERE device_id IN (?, ?)
	`, deviceAID, deviceBID).Scan(&cursorRows)
	if err != nil {
		t.Fatalf("count sync cursors: %v", err)
	}
	if cursorRows != 2 {
		t.Fatalf("expected two device scoped cursors, got %d", cursorRows)
	}
}

func TestDeleteObjectCreatesTombstoneChange(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	sessionID := createUploadSession(t, app, token, deviceID, rootID, "obj-delete", "ver-delete", 4)
	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("data"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	deletePath := fmt.Sprintf("/api/v1/objects/obj-delete?sync_root_id=%s&device_id=%s", rootID, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodDelete, deletePath, "", token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	changesPath := "/api/v1/changes?cursor=0&device_id=" + deviceID
	resp = testutil.JSONRequest(t, app, http.MethodGet, changesPath, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read changes body: %v", err)
	}
	if !strings.Contains(string(body), `"change_type":"delete"`) {
		t.Fatalf("expected delete change, got %s", string(body))
	}
	if !strings.Contains(string(body), `"object_id":"obj-delete"`) {
		t.Fatalf("expected deleted object id, got %s", string(body))
	}
}

func TestDeleteChangeAppearsAfterPriorCursor(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	sessionID := createUploadSession(t, app, token, deviceID, rootID, "obj-delete-after-cursor", "ver-delete-after-cursor", 4)
	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("data"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	changesPath := "/api/v1/changes?cursor=0&device_id=" + deviceID
	resp = testutil.JSONRequest(t, app, http.MethodGet, changesPath, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var firstPull struct {
		NextCursor int64 `json:"next_cursor"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&firstPull); err != nil {
		t.Fatalf("decode first changes response: %v", err)
	}
	if firstPull.NextCursor == 0 {
		t.Fatal("expected first pull to advance cursor")
	}

	deletePath := fmt.Sprintf("/api/v1/objects/obj-delete-after-cursor?sync_root_id=%s&device_id=%s", rootID, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodDelete, deletePath, "", token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, app, http.MethodGet, fmt.Sprintf("/api/v1/changes?cursor=%d&device_id=%s", firstPull.NextCursor, deviceID), "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read changes body: %v", err)
	}
	if !strings.Contains(string(body), `"change_type":"delete"`) {
		t.Fatalf("expected delete change after cursor %d, got %s", firstPull.NextCursor, string(body))
	}
}

func TestChangesPaginationReturnsHasMoreAndNextPage(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	for i := 1; i <= 3; i++ {
		uploadVersion(t, app, token, deviceID, rootID, fmt.Sprintf("obj-page-%d", i), fmt.Sprintf("ver-page-%d", i), []byte("data"))
	}

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0&device_id="+deviceID+"&limit=2", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	firstPage := decodeChangesPage(t, resp)
	if len(firstPage.Items) != 2 {
		t.Fatalf("expected first page to contain 2 changes, got %d", len(firstPage.Items))
	}
	if !firstPage.HasMore {
		t.Fatal("expected first page to report has_more=true")
	}
	if firstPage.NextCursor == 0 {
		t.Fatal("expected first page to advance next_cursor")
	}

	nextPath := fmt.Sprintf("/api/v1/changes?cursor=%d&device_id=%s&limit=2", firstPage.NextCursor, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodGet, nextPath, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	secondPage := decodeChangesPage(t, resp)
	if len(secondPage.Items) != 1 {
		t.Fatalf("expected second page to contain 1 change, got %d", len(secondPage.Items))
	}
	if secondPage.HasMore {
		t.Fatal("expected second page to report has_more=false")
	}
}

func TestChangesRejectsInvalidLimit(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0&limit=0", "", token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	testutil.AssertJSONErrorCode(t, resp, "invalid_request")
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

type changesPageResponse struct {
	Items []struct {
		ID          string `json:"id"`
		ChangeType  string `json:"change_type"`
		CursorValue int64  `json:"cursor_value"`
	} `json:"items"`
	NextCursor int64 `json:"next_cursor"`
	HasMore    bool  `json:"has_more"`
}

func decodeChangesPage(t *testing.T, resp *http.Response) changesPageResponse {
	t.Helper()
	var page changesPageResponse
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		t.Fatalf("decode changes page: %v", err)
	}
	return page
}

func uploadVersion(t *testing.T, app *httptest.Server, token, deviceID, rootID, objectID, versionID string, body []byte) {
	t.Helper()
	sessionID := createUploadSession(t, app, token, deviceID, rootID, objectID, versionID, int64(len(body)))
	resp := testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", body, token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
}
