package integration

import (
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestUnknownAPIRouteReturnsJSONEnvelope(t *testing.T) {
	app := testutil.NewTestServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/missing-route", "", "")
	testutil.AssertStatus(t, resp, http.StatusNotFound)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if payload.Success || payload.HTTPCode != http.StatusNotFound || payload.Message != "接口不存在" {
		t.Fatalf("unexpected unknown route payload: %+v", payload)
	}
}

func TestUnsupportedAPIMethodReturnsJSONEnvelope(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/upload-sessions", "", token)
	testutil.AssertStatus(t, resp, http.StatusMethodNotAllowed)
	payload := testutil.DecodeJSONEnvelope(t, resp)
	if payload.Success || payload.HTTPCode != http.StatusMethodNotAllowed || payload.Message != "当前接口不支持这个请求方式" {
		t.Fatalf("unexpected method payload: %+v", payload)
	}
}
