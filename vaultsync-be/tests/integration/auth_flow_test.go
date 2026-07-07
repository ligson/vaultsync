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
