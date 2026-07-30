package integration

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterDevice(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice MacBook","platform":"macos","client_key":"vaultsync-device:v1:macos:abc"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")
	if deviceID == "" {
		t.Fatal("expected device id")
	}
}

func TestRegisterDeviceReusesExistingClientKey(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	body := `{"name":"HUAWEI NOH-AN00","platform":"android","client_key":"vaultsync-device:v1:android:phone-key"}`
	first := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", body, token)
	testutil.AssertStatus(t, first, http.StatusCreated)
	firstID := testutil.MustReadJSONField(t, first, "id")

	second := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", body, token)
	testutil.AssertStatus(t, second, http.StatusCreated)
	secondID := testutil.MustReadJSONField(t, second, "id")

	if secondID != firstID {
		t.Fatalf("expected same physical device to reuse id %q, got %q", firstID, secondID)
	}
}

func TestRegisterDeviceClaimsSingleLegacyDevice(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	legacyBody := `{"name":"HUAWEI NOH-AN00","platform":"android"}`
	legacy := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", legacyBody, token)
	testutil.AssertStatus(t, legacy, http.StatusCreated)
	legacyID := testutil.MustReadJSONField(t, legacy, "id")

	nextBody := `{"name":"HUAWEI NOH-AN00","platform":"android","client_key":"vaultsync-device:v1:android:phone-key"}`
	next := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", nextBody, token)
	testutil.AssertStatus(t, next, http.StatusCreated)
	nextID := testutil.MustReadJSONField(t, next, "id")

	if nextID != legacyID {
		t.Fatalf("expected legacy device to be claimed as %q, got %q", legacyID, nextID)
	}
}

func TestRegisterDeviceClaimsLegacyDeviceWithSyncRoots(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	emptyLegacy := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", `{"name":"VaultSync android","platform":"android"}`, token)
	testutil.AssertStatus(t, emptyLegacy, http.StatusCreated)

	ownedLegacy := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", `{"name":"VaultSync android","platform":"android"}`, token)
	testutil.AssertStatus(t, ownedLegacy, http.StatusCreated)
	ownedLegacyID := testutil.MustReadJSONField(t, ownedLegacy, "id")
	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"keep","archive_path":""}`, ownedLegacyID)
	root := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, root, http.StatusCreated)

	nextBody := `{"name":"HUAWEI NOH-AN00","platform":"android","client_key":"vaultsync-device:v1:android:phone-key"}`
	next := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", nextBody, token)
	testutil.AssertStatus(t, next, http.StatusCreated)
	nextID := testutil.MustReadJSONField(t, next, "id")

	if nextID != ownedLegacyID {
		t.Fatalf("expected device with sync roots to be claimed as %q, got %q", ownedLegacyID, nextID)
	}
}
