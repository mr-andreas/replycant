package caserver

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func lanHandler(t *testing.T) http.Handler {
	t.Helper()
	handler, err := NewHandler(Config{CA: "pem-ca", ServerURL: "https://git.example"})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}
	return handler
}

// Verifies config endpoint stays machine-readable for webapp setup discovery.
func TestConfigJSONEndpoint(t *testing.T) {
	handler := lanHandler(t)

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
	handler := lanHandler(t)

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

// A preauth key is single-use, so serving a QR built at startup would leave
// every visitor after the first with a credential that can never join.
func TestTailnetConfigMintsAKeyPerRequest(t *testing.T) {
	calls := 0
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			calls++
			return "https://hs.example", "hskey-" + strings.Repeat("x", calls), nil
		},
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	first := getConfig(t, handler)
	second := getConfig(t, handler)

	if calls != 2 {
		t.Fatalf("mint should run once per GET, ran %d times", calls)
	}
	if first["ca"] != "pem-ca" || second["ca"] != "pem-ca" {
		t.Fatalf("unexpected ca in %#v / %#v", first, second)
	}
	if first["headscale_url"] != "https://hs.example" {
		t.Fatalf("unexpected headscale_url %q", first["headscale_url"])
	}
	if first["preauth_key"] == second["preauth_key"] {
		t.Fatal("each request must receive its own preauth key")
	}
	if _, ok := first["url"]; ok {
		t.Fatal("tailnet config must not advertise a gitd URL")
	}
}

// A mint failure must not serve a stale QR from an earlier successful request.
func TestTailnetConfigMintFailureIsUnavailable(t *testing.T) {
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			return "", "", errors.New("headscale is down")
		},
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	for _, path := range []string{"/config.json", "/", "/qr.png"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		resp := httptest.NewRecorder()
		handler.ServeHTTP(resp, req)
		if resp.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: got status %d, want 503", path, resp.Code)
		}
	}
}

func getConfig(t *testing.T, handler http.Handler) map[string]string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/config.json", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("unexpected status code: got %d", resp.Code)
	}
	var payload map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	return payload
}
