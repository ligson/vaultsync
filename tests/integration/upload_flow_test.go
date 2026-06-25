package integration

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestUploadCiphertextAndCompleteVersion(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)

	createBody := fmt.Sprintf(`{
		"device_id":"%s",
		"sync_root_id":"%s",
		"object_id":"obj-1",
		"version_id":"ver-1",
		"total_size":11,
		"chunk_size":5,
		"encrypted_name":"enc:file.txt",
		"metadata_json":"{\"nonce\":\"abc\"}"
	}`, deviceID, rootID)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	sessionID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte(" world"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
}

func TestListChangesAndDownloadCiphertext(t *testing.T) {
	app, token, versionID := testutil.NewUploadedVersionServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, versionID)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/objects/"+versionID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertHeader(t, resp, "Content-Type", "application/octet-stream")
}
