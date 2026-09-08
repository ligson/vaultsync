package integration

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestMediaTimelineIndexesAcrossDevicesAndPaginates(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)
	phoneID, phoneRoot := createMediaDeviceAndRoot(t, app, token, "Alice Phone", "phone")
	tabletID, tabletRoot := createMediaDeviceAndRoot(t, app, token, "Alice Tablet", "tablet")

	firstMediaID := uploadIndexedMedia(t, app, token, phoneID, phoneRoot,
		"photo-new", "version-new", "image", "2026-09-08T12:00:00Z")
	uploadIndexedMedia(t, app, token, tabletID, tabletRoot,
		"video-old", "version-old", "video", "2026-08-02T08:00:00Z")
	uploadIndexedMedia(t, app, token, phoneID, phoneRoot,
		"photo-second", "version-second", "image", "2026-09-07T12:00:00Z")

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/media/months", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var overview struct {
		Items []struct {
			Year  int   `json:"year"`
			Month int   `json:"month"`
			Count int64 `json:"count"`
		} `json:"items"`
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	decodeEnvelopeData(t, resp, &overview)
	if len(overview.Items) != 2 || overview.Items[0].Month != 9 || overview.Items[0].Count != 2 {
		t.Fatalf("unexpected media month overview: %+v", overview.Items)
	}
	if len(overview.Devices) != 2 {
		t.Fatalf("expected both devices in overview, got %+v", overview.Devices)
	}

	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/items?year=2026&month=9&limit=1", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var firstPage mediaPageResponse
	decodeEnvelopeData(t, resp, &firstPage)
	if len(firstPage.Items) != 1 || !firstPage.HasMore || firstPage.NextCursor == "" {
		t.Fatalf("unexpected first media page: %+v", firstPage)
	}
	if firstPage.Items[0].ID != firstMediaID {
		t.Fatalf("expected newest media %q, got %q", firstMediaID, firstPage.Items[0].ID)
	}

	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/items?year=2026&month=9&limit=1&cursor="+url.QueryEscape(firstPage.NextCursor), "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var secondPage mediaPageResponse
	decodeEnvelopeData(t, resp, &secondPage)
	if len(secondPage.Items) != 1 || secondPage.HasMore {
		t.Fatalf("unexpected second media page: %+v", secondPage)
	}

	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/items?year=2026&month=8&type=video&device_id="+tabletID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var filtered mediaPageResponse
	decodeEnvelopeData(t, resp, &filtered)
	if len(filtered.Items) != 1 || filtered.Items[0].DeviceID != tabletID || filtered.Items[0].MediaType != "video" {
		t.Fatalf("unexpected filtered media page: %+v", filtered)
	}
}

func TestMediaTimelineHidesDeletedObjectsAndProtectsThumbnails(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)
	deviceID, rootID := createMediaDeviceAndRoot(t, app, token, "Alice Phone", "phone")
	mediaID := uploadIndexedMedia(t, app, token, deviceID, rootID,
		"photo-delete", "version-delete", "image", "2026-09-08T12:00:00Z")

	thumbnail := []byte("opaque-encrypted-thumbnail")
	resp := testutil.BinaryRequest(t, app, http.MethodPut,
		"/api/v1/media/"+mediaID+"/thumbnail", thumbnail, token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.BinaryRequest(t, app, http.MethodGet,
		"/api/v1/media/"+mediaID+"/thumbnail", nil, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	got, err := io.ReadAll(resp.Body)
	if err != nil || string(got) != string(thumbnail) {
		t.Fatalf("unexpected thumbnail bytes %q: %v", string(got), err)
	}

	bobToken := registerAndLogin(t, app, "media-bob@example.com")
	resp = testutil.BinaryRequest(t, app, http.MethodGet,
		"/api/v1/media/"+mediaID+"/thumbnail", nil, bobToken)
	testutil.AssertStatus(t, resp, http.StatusNotFound)
	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/items?year=2026&month=9", "", bobToken)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var bobPage mediaPageResponse
	decodeEnvelopeData(t, resp, &bobPage)
	if len(bobPage.Items) != 0 {
		t.Fatalf("foreign user can see media: %+v", bobPage.Items)
	}

	resp = testutil.JSONRequest(t, app, http.MethodDelete,
		fmt.Sprintf("/api/v1/objects/photo-delete?device_id=%s&sync_root_id=%s", deviceID, rootID), "", token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/months", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var overview struct {
		Items []json.RawMessage `json:"items"`
	}
	decodeEnvelopeData(t, resp, &overview)
	if len(overview.Items) != 0 {
		t.Fatalf("deleted media remains in timeline: %+v", overview.Items)
	}
}

func TestMediaIndexRejectsOrdinarySyncRoot(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)
	body := fmt.Sprintf(`{
		"device_id":%q,"sync_root_id":%q,"object_id":"object",
		"version_id":"version","total_size":1,"chunk_size":1,
		"encrypted_name":"cipher","metadata_json":"{}",
		"media_index":{"media_type":"image","captured_at":"2026-09-08T12:00:00Z"}
	}`, deviceID, rootID)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", body, token)
	testutil.AssertStatus(t, resp, http.StatusBadRequest)
}

func TestMediaIndexBackfillIsNonDestructiveAndIdempotent(t *testing.T) {
	instance, app := testutil.NewTestAppAndServer(t)
	token := registerAndLogin(t, app, "media-backfill@example.com")
	deviceID, rootID := createMediaDeviceAndRoot(t, app, token, "Old Phone", "old-phone")
	mediaID := uploadIndexedMedia(t, app, token, deviceID, rootID,
		"old-photo", "old-version", "image", "2025-12-03T04:00:00Z")
	if _, err := instance.DB().Exec(`DELETE FROM media_assets WHERE id = ?`, mediaID); err != nil {
		t.Fatalf("remove only test index: %v", err)
	}

	body := fmt.Sprintf(`{"items":[{
		"sync_root_id":%q,"object_id":"old-photo","version_id":"old-version",
		"media_type":"image","captured_at":"2025-12-03T04:00:00Z"
	}]}`, rootID)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/media/indexes", body, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var result map[string]int
	decodeEnvelopeData(t, resp, &result)
	if result["indexed_count"] != 1 {
		t.Fatalf("expected one backfilled index, got %+v", result)
	}
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/media/indexes", body, token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	decodeEnvelopeData(t, resp, &result)
	if result["indexed_count"] != 0 {
		t.Fatalf("expected idempotent backfill, got %+v", result)
	}

	var versionCount int
	if err := instance.DB().QueryRow(`SELECT COUNT(*) FROM file_versions WHERE id = 'old-version'`).Scan(&versionCount); err != nil {
		t.Fatalf("count original version: %v", err)
	}
	if versionCount != 1 {
		t.Fatalf("backfill changed original file version count: %d", versionCount)
	}
}

func TestMediaCandidatesFindLatestUnindexedObjectsAcrossDevices(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)
	phoneID, phoneRoot := createMediaDeviceAndRoot(t, app, token, "Phone", "candidate-phone")
	tabletID, tabletRoot := createMediaDeviceAndRoot(t, app, token, "Tablet", "candidate-tablet")

	uploadUnindexedMediaObject(t, app, token, phoneID, phoneRoot,
		"candidate-photo", "candidate-photo-v1", "vaultsync-name:plain-v1:Y2FuZGlkYXRlLmpwZw==",
		`{"format":"vaultsync-metadata-plain-v1","relative_path":"Camera/2026/09/candidate.jpg"}`)
	uploadUnindexedMediaObject(t, app, token, tabletID, tabletRoot,
		"candidate-video", "candidate-video-v1", "vaultsync-name:plain-v1:Y2FuZGlkYXRlLm1wNA==",
		`{"format":"vaultsync-metadata-plain-v1","relative_path":"Camera/2025/12/candidate.mp4"}`)

	resp := testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/candidates?limit=1", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var firstPage domainRemoteBackupPage
	decodeEnvelopeData(t, resp, &firstPage)
	if len(firstPage.Items) != 1 || !firstPage.HasMore || firstPage.NextCursor == 0 {
		t.Fatalf("unexpected first candidate page: %+v", firstPage)
	}

	resp = testutil.JSONRequest(t, app, http.MethodGet,
		fmt.Sprintf("/api/v1/media/candidates?limit=1&cursor=%d", firstPage.NextCursor), "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var secondPage domainRemoteBackupPage
	decodeEnvelopeData(t, resp, &secondPage)
	if len(secondPage.Items) != 1 || secondPage.HasMore {
		t.Fatalf("unexpected second candidate page: %+v", secondPage)
	}

	indexBody := fmt.Sprintf(`{"items":[{"sync_root_id":%q,"object_id":%q,"version_id":%q,"media_type":"image","captured_at":"2026-09-08T00:00:00Z"}]}`,
		phoneRoot, "candidate-photo", "candidate-photo-v1")
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/media/indexes", indexBody, token)
	testutil.AssertStatus(t, resp, http.StatusOK)

	resp = testutil.JSONRequest(t, app, http.MethodGet,
		"/api/v1/media/candidates", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	var remaining domainRemoteBackupPage
	decodeEnvelopeData(t, resp, &remaining)
	if len(remaining.Items) != 1 || remaining.Items[0].ObjectID != "candidate-video" {
		t.Fatalf("indexed object was not removed from candidates: %+v", remaining)
	}
}

type mediaPageResponse struct {
	Items []struct {
		ID        string `json:"id"`
		DeviceID  string `json:"device_id"`
		MediaType string `json:"media_type"`
	} `json:"items"`
	NextCursor string `json:"next_cursor"`
	HasMore    bool   `json:"has_more"`
}

type domainRemoteBackupPage struct {
	Items []struct {
		ObjectID  string `json:"object_id"`
		VersionID string `json:"version_id"`
	} `json:"items"`
	NextCursor int64 `json:"next_cursor"`
	HasMore    bool  `json:"has_more"`
}

func createMediaDeviceAndRoot(t *testing.T, app *httptest.Server, token, name, suffix string) (string, string) {
	t.Helper()
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices",
		fmt.Sprintf(`{"name":%q,"platform":"android","client_key":%q}`, name, "media-"+suffix), token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots",
		fmt.Sprintf(`{"device_id":%q,"encrypted_path":%q,"encryption_enabled":true,"cleanup_policy":"keep","archive_path":""}`, deviceID, "media-backup:v1:"+suffix), token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	return deviceID, testutil.MustReadJSONField(t, resp, "id")
}

func uploadIndexedMedia(t *testing.T, app *httptest.Server, token, deviceID, rootID, objectID, versionID, mediaType, capturedAt string) string {
	t.Helper()
	body := fmt.Sprintf(`{
		"device_id":%q,"sync_root_id":%q,"object_id":%q,"version_id":%q,
		"total_size":1,"chunk_size":1,"encrypted_name":"cipher",
		"metadata_json":"{}","media_index":{"media_type":%q,"captured_at":%q}
	}`, deviceID, rootID, objectID, versionID, mediaType, capturedAt)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", body, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	sessionID := testutil.MustReadJSONField(t, resp, "id")
	resp = testutil.BinaryRequest(t, app, http.MethodPut,
		"/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("x"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost,
		"/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	return testutil.MustReadJSONField(t, resp, "media_id")
}

func uploadUnindexedMediaObject(t *testing.T, app *httptest.Server, token, deviceID, rootID, objectID, versionID, encryptedName, metadataJSON string) {
	t.Helper()
	body := fmt.Sprintf(`{"device_id":%q,"sync_root_id":%q,"object_id":%q,"version_id":%q,"total_size":1,"chunk_size":1,"encrypted_name":%q,"metadata_json":%q}`,
		deviceID, rootID, objectID, versionID, encryptedName, metadataJSON)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", body, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	sessionID := testutil.MustReadJSONField(t, resp, "id")
	resp = testutil.BinaryRequest(t, app, http.MethodPut,
		"/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("x"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost,
		"/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
}

func decodeEnvelopeData(t *testing.T, resp *http.Response, target any) {
	t.Helper()
	envelope := testutil.DecodeJSONEnvelope(t, resp)
	if err := json.Unmarshal(envelope.Data, target); err != nil {
		t.Fatalf("decode envelope data: %v", err)
	}
}
