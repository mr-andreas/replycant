package caserver

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func notBootstrapped() (bool, error) { return false, nil }

// The page exists only to put the first device on the tailnet. Without a
// minter it has nothing to offer, and without the bootstrap check it would
// keep handing out join keys after the first push.
func TestNewHandlerRequiresAMinterAndABootstrapCheck(t *testing.T) {
	mint := func() (string, string, error) { return "https://hs.example", "hskey", nil }
	if _, err := NewHandler(Config{CA: "pem-ca", Bootstrapped: notBootstrapped}); err == nil {
		t.Error("a page without a minter must be rejected")
	}
	if _, err := NewHandler(Config{CA: "pem-ca", Mint: mint}); err == nil {
		t.Error("a page without a bootstrap check must be rejected")
	}
}

// The CA page listens on the whole LAN by default, so any website the
// operator visits could otherwise preflight and read a freshly minted join
// key. A preflight is refused outright, and refusing it must not mint.
func TestConfigJSONRefusesCrossOriginPreflight(t *testing.T) {
	calls := 0
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			calls++
			return "https://hs.example", "hskey-x", nil
		},
		Bootstrapped: notBootstrapped,
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	req := httptest.NewRequest(http.MethodOptions, "/config.json", nil)
	req.Header.Set("Origin", "https://attacker.example")
	req.Header.Set("Access-Control-Request-Method", http.MethodGet)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)

	if resp.Code != http.StatusMethodNotAllowed {
		t.Fatalf("unexpected status code: got %d want %d", resp.Code, http.StatusMethodNotAllowed)
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("a preflight must not grant cross-origin access, got %q", got)
	}
	if calls != 0 {
		t.Fatalf("a refused preflight minted %d keys", calls)
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
		Bootstrapped: notBootstrapped,
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

// The payload carries a live join key, so no other origin may read it.
func TestConfigJSONIsSameOriginJSON(t *testing.T) {
	handler, err := NewHandler(Config{
		CA:           "pem-ca",
		Mint:         func() (string, string, error) { return "https://hs.example", "hskey", nil },
		Bootstrapped: notBootstrapped,
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/config.json", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if got := resp.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("unexpected content-type: got %q want %q", got, "application/json")
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("config.json must not allow cross-origin reads, got %q", got)
	}
}

// A mint failure must not serve a stale QR from an earlier successful request.
func TestTailnetConfigMintFailureIsUnavailable(t *testing.T) {
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			return "", "", errors.New("headscale is down")
		},
		Bootstrapped: notBootstrapped,
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

// The page may be published on the LAN, where anyone can open it. Once the
// first device has pushed, a join key is of no use to a legitimate visitor, so
// the page must stop minting rather than hand out tailnet credentials.
func TestTailnetConfigIsGoneOnceBootstrapped(t *testing.T) {
	minted := 0
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			minted++
			return "https://hs.example", "hskey", nil
		},
		Bootstrapped: func() (bool, error) { return true, nil },
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	for _, path := range []string{"/config.json", "/", "/qr.png"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		resp := httptest.NewRecorder()
		handler.ServeHTTP(resp, req)
		if resp.Code != http.StatusGone {
			t.Errorf("%s: got status %d, want 410", path, resp.Code)
		}
		if strings.Contains(resp.Body.String(), "hskey") {
			t.Errorf("%s: a bootstrapped page must not leak a join key", path)
		}
	}
	if minted != 0 {
		t.Fatalf("a bootstrapped page must not mint, minted %d keys", minted)
	}
}

// If the repository cannot be read, the page cannot tell whether the bootstrap
// window is still open. It must fail closed instead of minting a key.
func TestTailnetConfigBootstrapCheckFailureIsUnavailable(t *testing.T) {
	minted := 0
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			minted++
			return "https://hs.example", "hskey", nil
		},
		Bootstrapped: func() (bool, error) { return false, errors.New("repository unreadable") },
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
	if minted != 0 {
		t.Fatalf("an unknown bootstrap state must not mint, minted %d keys", minted)
	}
}

// While the repository is still empty the page is the first device's only way
// onto the tailnet, so the gate must let every request through to the mint.
func TestTailnetConfigMintsWhileNotBootstrapped(t *testing.T) {
	minted := 0
	handler, err := NewHandler(Config{
		CA: "pem-ca",
		Mint: func() (string, string, error) {
			minted++
			return "https://hs.example", "hskey", nil
		},
		Bootstrapped: func() (bool, error) { return false, nil },
	})
	if err != nil {
		t.Fatalf("NewHandler() error = %v", err)
	}

	if got := getConfig(t, handler)["preauth_key"]; got != "hskey" {
		t.Fatalf("unexpected preauth_key %q", got)
	}
	if minted != 1 {
		t.Fatalf("expected one mint, got %d", minted)
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
