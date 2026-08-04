package caserver

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Verifies config endpoint stays machine-readable for webapp setup discovery.
func TestConfigJSONEndpoint(t *testing.T) {
	handler, err := NewHandler("pem-ca", "https://git.example")
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/config.json", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("unexpected status code: got %d want %d", resp.Code, http.StatusOK)
	}
	if got := resp.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("unexpected content-type: got %q want %q", got, "application/json")
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("unexpected CORS origin header: got %q want %q", got, "*")
	}

	var payload map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	if payload["ca"] != "pem-ca" {
		t.Fatalf("unexpected ca: got %q want %q", payload["ca"], "pem-ca")
	}
	if payload["url"] != "https://git.example" {
		t.Fatalf("unexpected url: got %q want %q", payload["url"], "https://git.example")
	}
}

// Verifies preflight requests succeed so browser-based setup discovery can call the endpoint cross-origin.
func TestConfigJSONEndpointOptions(t *testing.T) {
	handler, err := NewHandler("pem-ca", "https://git.example")
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	req := httptest.NewRequest(http.MethodOptions, "/config.json", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)

	if resp.Code != http.StatusNoContent {
		t.Fatalf("unexpected status code: got %d want %d", resp.Code, http.StatusNoContent)
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("unexpected CORS origin header: got %q want %q", got, "*")
	}
	if got := resp.Header().Get("Access-Control-Allow-Methods"); got != "GET, OPTIONS" {
		t.Fatalf("unexpected CORS methods header: got %q want %q", got, "GET, OPTIONS")
	}
}
