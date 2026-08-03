package integration

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

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
	payload = testutil.DecodeJSONEnvelope(t, resp)
	var session struct {
		Token            string `json:"token"`
		RefreshToken     string `json:"refresh_token"`
		RefreshExpiresAt string `json:"refresh_expires_at"`
	}
	if err := json.Unmarshal(payload.Data, &session); err != nil {
		t.Fatalf("decode login session: %v", err)
	}
	if session.Token == "" || session.RefreshToken == "" {
		t.Fatalf("expected access and refresh tokens, got %+v", session)
	}
	refreshExpiresAt, err := time.Parse(time.RFC3339, session.RefreshExpiresAt)
	if err != nil {
		t.Fatalf("parse refresh expiry: %v", err)
	}
	remaining := time.Until(refreshExpiresAt)
	if remaining < 29*24*time.Hour || remaining > 31*24*time.Hour {
		t.Fatalf("unexpected refresh lifetime: %s", remaining)
	}
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

func TestRefreshTokenRotatesWithoutBearerToken(t *testing.T) {
	server := testutil.NewTestServer(t)
	resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/register", `{"email":"alice@example.com","password":"passw0rd!"}`, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", `{"email":"alice@example.com","password":"passw0rd!"}`, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	firstRefreshToken := testutil.MustReadJSONField(t, resp, "refresh_token")

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/refresh", `{"refresh_token":"`+firstRefreshToken+`"}`, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	secondRefreshToken := testutil.MustReadJSONField(t, resp, "refresh_token")
	if secondRefreshToken == firstRefreshToken {
		t.Fatal("expected refresh token rotation")
	}

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/refresh", `{"refresh_token":"`+firstRefreshToken+`"}`, "")
	testutil.AssertStatus(t, resp, http.StatusUnauthorized)

	resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/refresh", `{"refresh_token":"`+secondRefreshToken+`"}`, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
}

func TestRefreshTokenRejectsInvalidExpiredAndRevokedSessions(t *testing.T) {
	t.Run("invalid", func(t *testing.T) {
		server := testutil.NewTestServer(t)
		resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/refresh", `{"refresh_token":"invalid"}`, "")
		testutil.AssertStatus(t, resp, http.StatusUnauthorized)
	})

	for _, testCase := range []struct {
		name   string
		column string
		value  string
	}{
		{name: "expired", column: "refresh_expires_at", value: "2000-01-01T00:00:00Z"},
		{name: "revoked", column: "revoked_at", value: "2026-08-03T00:00:00Z"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			instance, server := testutil.NewTestAppAndServer(t)
			resp := testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/register", `{"email":"alice@example.com","password":"passw0rd!"}`, "")
			testutil.AssertStatus(t, resp, http.StatusCreated)
			resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", `{"email":"alice@example.com","password":"passw0rd!"}`, "")
			testutil.AssertStatus(t, resp, http.StatusOK)
			refreshToken := testutil.MustReadJSONField(t, resp, "refresh_token")

			if _, err := instance.DB().Exec(`UPDATE sessions SET `+testCase.column+` = ?`, testCase.value); err != nil {
				t.Fatalf("update session: %v", err)
			}
			resp = testutil.JSONRequest(t, server, http.MethodPost, "/api/v1/auth/refresh", `{"refresh_token":"`+refreshToken+`"}`, "")
			testutil.AssertStatus(t, resp, http.StatusUnauthorized)
		})
	}
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
