package integration

import (
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
