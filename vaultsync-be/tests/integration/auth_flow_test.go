package integration

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterAndLogin(t *testing.T) {
	app := testutil.NewTestServer(t)

	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if !payload.Success || payload.HTTPCode != http.StatusCreated {
		t.Fatalf("expected unified envelope on register, got %+v", payload)
	}

	loginBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"token":"`)
}

func TestRegisterDuplicateEmailReturnsReadableError(t *testing.T) {
	app := testutil.NewTestServer(t)

	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if payload.Message != "该邮箱已注册，请直接登录或更换邮箱" {
		t.Fatalf("expected readable duplicate email message, got %q", payload.Message)
	}
	var data struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(payload.Data, &data); err != nil {
		t.Fatalf("decode error data: %v", err)
	}
	if data.Code != "invalid_request" {
		t.Fatalf("expected invalid_request code, got %q", data.Code)
	}
}

func TestProtectedRoutesReturnJSONUnauthorized(t *testing.T) {
	app := testutil.NewTestServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", `{"name":"Phone","platform":"ios"}`, "")
	testutil.AssertStatus(t, resp, http.StatusUnauthorized)
	testutil.AssertJSONErrorCode(t, resp, "unauthorized")
}

func TestLoginFailureReturnsStableUnauthorizedCode(t *testing.T) {
	app := testutil.NewTestServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", `{"email":"missing@example.com","password":"bad"}`, "")
	testutil.AssertStatus(t, resp, http.StatusUnauthorized)
	testutil.AssertJSONErrorCode(t, resp, "unauthorized")
}

func TestAuthRefreshReturnsNewSession(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/refresh", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"token":"`)
}

func TestUserCanReadAndUpdateProfile(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/auth/me", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	var initial struct {
		Email      string `json:"email"`
		QuotaBytes int64  `json:"quota_bytes"`
		UsedBytes  int64  `json:"used_bytes"`
	}
	if err := json.Unmarshal(payload.Data, &initial); err != nil {
		t.Fatalf("decode profile: %v", err)
	}
	if initial.Email != "alice@example.com" || initial.QuotaBytes <= 0 || initial.UsedBytes != 0 {
		t.Fatalf("unexpected initial profile: %+v", initial)
	}

	resp = testutil.JSONRequest(t, app, http.MethodPatch, "/api/v1/auth/me", `{"username":"alice.cloud","nickname":"Alice"}`, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	payload = testutil.DecodeJSONEnvelope(t, resp)
	var updated struct {
		Username string `json:"username"`
		Nickname string `json:"nickname"`
	}
	if err := json.Unmarshal(payload.Data, &updated); err != nil {
		t.Fatalf("decode updated profile: %v", err)
	}
	if updated.Username != "alice.cloud" || updated.Nickname != "Alice" {
		t.Fatalf("unexpected updated profile: %+v", updated)
	}
}

func TestUserCanChangePasswordWithCurrentPassword(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/change-password", `{"current_password":"wrong","new_password":"new-passw0rd!"}`, token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)

	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/change-password", `{"current_password":"passw0rd!","new_password":"new-passw0rd!"}`, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	_ = resp.Body.Close()

	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", `{"email":"alice@example.com","password":"new-passw0rd!"}`, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
}

func TestReleaseMetadataIsPubliclyReadable(t *testing.T) {
	app := testutil.NewTestServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/releases/android", "", "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"platform":"android"`)
}
