package integration

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/ligson/vaultsync/internal/config"
	"github.com/ligson/vaultsync/internal/testutil"
)

func TestAdminRegisterLoginAndReadConsoleData(t *testing.T) {
	server := testutil.NewTestServer(t)

	registerBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	testutil.AssertJSONContains(t, resp, `"role":"admin"`)

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	for _, path := range []string{
		"/api/v1/admin/me",
		"/api/v1/admin/overview",
		"/api/v1/admin/users",
		"/api/v1/admin/settings",
		"/api/v1/admin/downloads",
	} {
		resp = testutil.JSONRequest(t, server, http.MethodGet, path, "", adminToken)
		testutil.AssertStatus(t, resp, http.StatusOK)
	}
}

func TestAdminOverviewReturnsEmptyEventArray(t *testing.T) {
	server := testutil.NewTestServer(t)

	registerBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	resp = testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/overview", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"recent_events":[]`)
}

func TestAdminRegistrationCanBeDisabled(t *testing.T) {
	dataDir := t.TempDir()
	_, server := testutil.NewTestAppAndServerWithConfig(t, config.Config{
		HTTPAddr:                 "127.0.0.1:0",
		DataDir:                  dataDir,
		DatabasePath:             filepath.Join(dataDir, "vaultsync.db"),
		TokenSecret:              "test-secret",
		AdminRegistrationEnabled: false,
	})

	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", `{"email":"admin@example.com","password":"passw0rd!"}`, "")
	testutil.AssertStatus(t, resp, http.StatusForbidden)
	testutil.AssertJSONContains(t, resp, "管理员注册已关闭")
}

func TestNormalUserCannotReadAdminAPI(t *testing.T) {
	server, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/overview", "", token)
	testutil.AssertStatus(t, resp, http.StatusForbidden)
	testutil.AssertJSONErrorCode(t, resp, "forbidden")
}

func TestAdminCanUpdateUserSettingsAndDownloads(t *testing.T) {
	server := testutil.NewTestServer(t)

	adminBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/register", `{"email":"user@example.com","password":"passw0rd!"}`, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	userID := testutil.MustReadJSONField(t, resp, "id")

	updateUserBody := `{"status":"disabled","quota_bytes":2147483648}`
	resp = testutil.JSONRequest(t, server, http.MethodPatch, "/api/v1/admin/users/"+userID, updateUserBody, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"status":"disabled"`)) || !bytes.Contains(payload.Data, []byte(`"quota_bytes":2147483648`)) {
		t.Fatalf("unexpected updated user payload: %s", string(payload.Data))
	}

	settingsBody := `{"version_retention_count":9,"max_upload_bytes":1073741824,"default_cleanup_policy":"delete"}`
	resp = testutil.JSONRequest(t, server, http.MethodPut, "/api/v1/admin/settings", settingsBody, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload = testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"version_retention_count":9`)) || !bytes.Contains(payload.Data, []byte(`"default_cleanup_policy":"delete"`)) {
		t.Fatalf("unexpected settings payload: %s", string(payload.Data))
	}

	downloadBody := `{"file_name":"vaultsync-android-latest.apk","version":"1.0.1","download_url":"/downloads/vaultsync-android-latest.apk"}`
	resp = testutil.JSONRequest(t, server, http.MethodPut, "/api/v1/admin/downloads/android", downloadBody, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"version":"1.0.1"`)
}

func TestAdminCanCreateLockAndResetUserPassword(t *testing.T) {
	server := testutil.NewTestServer(t)

	adminBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	createUserBody := `{"email":"new-user@example.com","password":"old-passw0rd","quota_bytes":3221225472}`
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/users", createUserBody, adminToken)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	createPayload := testutil.DecodeJSONEnvelope(t, resp)
	var createdUser struct {
		ID         string `json:"id"`
		Role       string `json:"role"`
		QuotaBytes int64  `json:"quota_bytes"`
	}
	if err := json.Unmarshal(createPayload.Data, &createdUser); err != nil {
		t.Fatalf("decode created user: %v", err)
	}
	if createdUser.ID == "" || createdUser.Role != "user" || createdUser.QuotaBytes != 3221225472 {
		t.Fatalf("unexpected created user payload: %s", string(createPayload.Data))
	}
	userID := createdUser.ID

	resp = testutil.JSONRequest(t, server, http.MethodPatch, "/api/v1/admin/users/"+userID, `{"status":"disabled","quota_bytes":3221225472}`, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", `{"email":"new-user@example.com","password":"old-passw0rd"}`, "")
	testutil.AssertStatus(t, resp, http.StatusForbidden)
	testutil.AssertJSONContains(t, resp, "账号已被禁用")

	resp = testutil.JSONRequest(t, server, http.MethodPatch, "/api/v1/admin/users/"+userID, `{"status":"active","quota_bytes":3221225472}`, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/users/"+userID+"/reset-password", `{"password":"new-passw0rd"}`, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, "用户密码已重置")

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", `{"email":"new-user@example.com","password":"old-passw0rd"}`, "")
	testutil.AssertStatus(t, resp, http.StatusUnauthorized)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", `{"email":"new-user@example.com","password":"new-passw0rd"}`, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
}

func TestAdminCanUploadDownloadReleaseFile(t *testing.T) {
	server := testutil.NewTestServer(t)

	adminBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("version", "2.0.0"); err != nil {
		t.Fatalf("write version field: %v", err)
	}
	part, err := writer.CreateFormFile("file", "vaultsync-android-latest.apk")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write([]byte("apk-bytes")); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	req, err := http.NewRequest(http.MethodPost, server.URL+"/api/v1/admin/downloads/android/upload", &body)
	if err != nil {
		t.Fatalf("new upload request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do upload request: %v", err)
	}
	testutil.AssertStatus(t, resp, http.StatusCreated)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"download_url":"/downloads/vaultsync-android-latest.apk"`)) ||
		!bytes.Contains(payload.Data, []byte(`"size_bytes":9`)) {
		t.Fatalf("unexpected upload payload: %s", string(payload.Data))
	}

	resp, err = http.Get(server.URL + "/downloads/vaultsync-android-latest.apk")
	if err != nil {
		t.Fatalf("download release file: %v", err)
	}
	testutil.AssertStatus(t, resp, http.StatusOK)
	downloaded, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read downloaded release: %v", err)
	}
	if string(downloaded) != "apk-bytes" {
		t.Fatalf("unexpected downloaded file content: %q", string(downloaded))
	}

	resp = testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/downloads", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload = testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"platform":"android"`)) ||
		!bytes.Contains(payload.Data, []byte(`"size_bytes":9`)) ||
		!bytes.Contains(payload.Data, []byte(`"platform":"macos"`)) {
		t.Fatalf("unexpected downloads payload: %s", string(payload.Data))
	}

	updateBody := `{"file_name":"vaultsync-android-latest.apk","version":"2.0.1","download_url":"/downloads/vaultsync-android-latest.apk"}`
	resp = testutil.JSONRequest(t, server, http.MethodPut, "/api/v1/admin/downloads/android", updateBody, adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload = testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"version":"2.0.1"`)) ||
		!bytes.Contains(payload.Data, []byte(`"size_bytes":9`)) {
		t.Fatalf("unexpected updated download payload: %s", string(payload.Data))
	}
}

func TestAdminDownloadUploadValidatesPlatformFileType(t *testing.T) {
	server := testutil.NewTestServer(t)
	adminToken := registerAndLoginAdmin(t, server)

	resp := uploadDownloadRelease(t, server, adminToken, "android", "2.0.0", "vaultsync-android-latest.zip", []byte("zip-bytes"))
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	testutil.AssertJSONContains(t, resp, "Android 安装包必须是 .apk 文件")
}

func TestAdminCanDeleteDownloadReleaseFile(t *testing.T) {
	server := testutil.NewTestServer(t)
	adminToken := registerAndLoginAdmin(t, server)

	resp := uploadDownloadRelease(t, server, adminToken, "android", "2.0.0", "vaultsync-android-latest.apk", []byte("apk-bytes"))
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, server, http.MethodDelete, "/api/v1/admin/downloads/android/file", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, "安装包文件已删除")

	resp, err := http.Get(server.URL + "/downloads/vaultsync-android-latest.apk")
	if err != nil {
		t.Fatalf("download deleted release file: %v", err)
	}
	testutil.AssertStatus(t, resp, http.StatusNotFound)

	resp = testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/downloads", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"platform":"android"`)) ||
		!bytes.Contains(payload.Data, []byte(`"size_bytes":0`)) {
		t.Fatalf("unexpected downloads payload: %s", string(payload.Data))
	}
}

func TestAdminAuditLogsAndSystemStatus(t *testing.T) {
	server := testutil.NewTestServer(t)

	adminBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	adminToken := testutil.MustReadJSONField(t, resp, "token")

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/users", `{"email":"audit-user@example.com","password":"passw0rd!","quota_bytes":1073741824}`, adminToken)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/audit-logs", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"action":"admin.user.create"`)) || !bytes.Contains(payload.Data, []byte(`"actor_user_id"`)) {
		t.Fatalf("unexpected audit log payload: %s", string(payload.Data))
	}

	resp = testutil.JSONRequest(t, server, http.MethodGet, "/api/v1/admin/system/status", "", adminToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload = testutil.DecodeJSONEnvelope(t, resp)
	if !bytes.Contains(payload.Data, []byte(`"status":"ok"`)) ||
		!bytes.Contains(payload.Data, []byte(`"database_path"`)) ||
		!bytes.Contains(payload.Data, []byte(`"download_dir"`)) ||
		!bytes.Contains(payload.Data, []byte(`"storage_used_bytes"`)) {
		t.Fatalf("unexpected system status payload: %s", string(payload.Data))
	}
}

func registerAndLoginAdmin(t *testing.T, server *httptest.Server) string {
	t.Helper()

	adminBody := `{"email":"admin@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/register", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/admin/auth/login", adminBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	return testutil.MustReadJSONField(t, resp, "token")
}

func uploadDownloadRelease(t *testing.T, server *httptest.Server, token, platform, version, fileName string, content []byte) *http.Response {
	t.Helper()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("version", version); err != nil {
		t.Fatalf("write version field: %v", err)
	}
	part, err := writer.CreateFormFile("file", fileName)
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	req, err := http.NewRequest(http.MethodPost, server.URL+"/api/v1/admin/downloads/"+platform+"/upload", &body)
	if err != nil {
		t.Fatalf("new upload request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do upload request: %v", err)
	}
	return resp
}
