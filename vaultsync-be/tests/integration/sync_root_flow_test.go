package integration

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterAndManageSyncRoots(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"delete","archive_path":""}`, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/sync-roots", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"cleanup_policy":"delete"`)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/sync-roots", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"device_name":"Alice MacBook"`)
}

func TestSyncRootRemoteObjectsSubrouteReturnsJSONEnvelope(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice Phone","platform":"android"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"keep","archive_path":""}`, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	rootID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/sync-roots/"+rootID+"/remote-objects", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var payload struct {
		Success  bool `json:"success"`
		HTTPCode int  `json:"httpCode"`
		Data     struct {
			Items []any `json:"items"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode remote objects json envelope: %v", err)
	}
	if !payload.Success || payload.HTTPCode != http.StatusOK || payload.Data.Items == nil {
		t.Fatalf("unexpected remote objects payload: %+v", payload)
	}
}

func TestUpdateAndDeleteSyncRootRoutes(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice Phone","platform":"android"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"keep","archive_path":""}`, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	rootID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.JSONRequest(t, app, http.MethodPatch, "/api/v1/sync-roots/"+rootID, `{"cleanup_policy":"delete"}`, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"cleanup_policy":"delete"`)

	resp = testutil.JSONRequest(t, app, http.MethodDelete, "/api/v1/sync-roots/"+rootID+"?delete_remote=false", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"delete_remote":false`)
}

func TestSyncRootRejectsForeignDevice(t *testing.T) {
	app := testutil.NewTestServer(t)
	aliceToken := registerAndLogin(t, app, "alice@example.com")
	bobToken := registerAndLogin(t, app, "bob@example.com")

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, aliceToken)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	aliceDeviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:bob-path","cleanup_policy":"keep","archive_path":""}`, aliceDeviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, bobToken)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
}

func TestSyncRootInvalidJSONReturnsJSONError(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", `{"device_id":`, token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	testutil.AssertJSONErrorCode(t, resp, "invalid_request")
}

func registerAndLogin(t *testing.T, app *httptest.Server, email string) string {
	t.Helper()
	registerBody := fmt.Sprintf(`{"email":"%s","password":"passw0rd!"}`, email)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)

	loginBody := fmt.Sprintf(`{"email":"%s","password":"passw0rd!"}`, email)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	return testutil.MustReadJSONField(t, resp, "token")
}
