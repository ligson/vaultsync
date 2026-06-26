package integration

import (
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterDevice(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")
	if deviceID == "" {
		t.Fatal("expected device id")
	}
}
