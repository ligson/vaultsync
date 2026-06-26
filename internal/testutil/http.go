package testutil

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func JSONRequest(t *testing.T, server *httptest.Server, method, path, body, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	return resp
}

func BinaryRequest(t *testing.T, server *httptest.Server, method, path string, body []byte, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, server.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	return resp
}

func AssertStatus(t *testing.T, resp *http.Response, want int) {
	t.Helper()
	if resp.StatusCode != want {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected status %d, got %d: %s", want, resp.StatusCode, string(body))
	}
}

func AssertJSONContains(t *testing.T, resp *http.Response, want string) {
	t.Helper()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	if !strings.Contains(string(body), want) {
		t.Fatalf("expected response body to contain %q, got %s", want, string(body))
	}
}

func AssertJSONErrorCode(t *testing.T, resp *http.Response, want string) {
	t.Helper()
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode json error: %v", err)
	}
	if payload.Error.Code != want {
		t.Fatalf("expected json error code %q, got %q", want, payload.Error.Code)
	}
}

func MustReadJSONField(t *testing.T, resp *http.Response, field string) string {
	t.Helper()
	var payload map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode json: %v", err)
	}
	value, ok := payload[field].(string)
	if !ok || value == "" {
		t.Fatalf("expected json field %q to be a non-empty string", field)
	}
	return value
}

func AssertHeader(t *testing.T, resp *http.Response, key, want string) {
	t.Helper()
	got := resp.Header.Get(key)
	if got != want {
		t.Fatalf("expected header %s=%q, got %q", key, want, got)
	}
}
