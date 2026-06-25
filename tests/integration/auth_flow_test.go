package integration

import (
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterAndLogin(t *testing.T) {
	app := testutil.NewTestServer(t)

	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)

	loginBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"token":"`)
}
