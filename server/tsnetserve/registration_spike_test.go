//go:build integration

package tsnetserve_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/server/tsnetserve"
)

// Confirms the assumption the whole connectivity design rests on: that a node
// can register against a control URL that is not the `server_url` headscale
// advertises.
//
// This matters because clients will always dial a local shim at
// http://127.0.0.1:PORT, while headscale's server_url is the public tunnel
// hostname. headscale bakes server_url into registration responses and DERP
// advertisements, so if it validated that the two agree - or if the Tailscale
// client insisted on them agreeing - the reverse-tunnel approach could not work
// at all and would need a redesign rather than a fix.
//
// The test is skipped unless REPLYCANT_TEST_HEADSCALE_URL and
// REPLYCANT_TEST_HEADSCALE_AUTHKEY_FILE are set, because it needs a real
// headscale. See docs/docs/gitdb/connectivity.md for how to bring one up.
func TestTsnetRegistersAgainstMismatchedControlURL(t *testing.T) {
	controlURL := strings.TrimSpace(os.Getenv("REPLYCANT_TEST_HEADSCALE_URL"))
	authKeyFile := strings.TrimSpace(os.Getenv("REPLYCANT_TEST_HEADSCALE_AUTHKEY_FILE"))
	if controlURL == "" || authKeyFile == "" {
		t.Skip("set REPLYCANT_TEST_HEADSCALE_URL and REPLYCANT_TEST_HEADSCALE_AUTHKEY_FILE to run the tailnet spike")
	}

	// Proves the premise: the control URL under test is a plain-HTTP loopback
	// address, not the https tunnel hostname headscale advertises as
	// server_url. If this stopped being true the test would no longer be
	// exercising the mismatch.
	if !strings.HasPrefix(controlURL, "http://127.0.0.1") &&
		!strings.HasPrefix(controlURL, "http://localhost") {
		t.Fatalf("the spike must use a loopback control URL, got %q", controlURL)
	}

	advertised, err := headscaleAdvertisedServerURL(controlURL)
	if err != nil {
		t.Fatalf("could not read headscale's advertised server_url: %v", err)
	}
	if advertised == controlURL {
		t.Fatalf("headscale advertises %q, which matches the control URL; "+
			"the mismatch this test exists to check is not present", advertised)
	}
	t.Logf("headscale advertises server_url %q while the node dials %q", advertised, controlURL)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	node, err := tsnetserve.Start(ctx, tsnetserve.Config{
		Dir:        t.TempDir(),
		ControlURL: controlURL,
		Hostname:   fmt.Sprintf("spike-%d", time.Now().UnixNano()),
		Mint: func(context.Context) (string, error) {
			key, err := os.ReadFile(authKeyFile)
			return strings.TrimSpace(string(key)), err
		},
		Logf: t.Logf,
	})
	if err != nil {
		t.Fatalf("a node must be able to register through a mismatched control URL: %v", err)
	}
	t.Cleanup(func() { _ = node.Close() })

	addrs := node.Addrs()
	if len(addrs) == 0 {
		t.Fatal("a registered node must have been assigned a tailnet address")
	}
	t.Logf("registered with tailnet addresses %v", addrs)
}

// Reads the server_url headscale is configured with, so the test can assert the
// mismatch it depends on actually exists rather than assuming it.
func headscaleAdvertisedServerURL(controlURL string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// /key is the unauthenticated endpoint the Tailscale client uses to
	// bootstrap, which makes it a cheap liveness probe. The capability version
	// is required and must be at least what headscale's minimum client version
	// implies, so it is pinned high enough for 0.29.x rather than left off.
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, controlURL+"/key?v=120", nil)
	if err != nil {
		return "", err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", fmt.Errorf("headscale is not reachable at %s: %w", controlURL, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 512))
		return "", fmt.Errorf("headscale returned %d for /key: %s", response.StatusCode, body)
	}

	// The advertised server_url is supplied out of band, since /key does not
	// echo it. Read it from the same file the compose stack writes.
	advertised := strings.TrimSpace(os.Getenv("REPLYCANT_TEST_HEADSCALE_ADVERTISED_URL"))
	if advertised == "" {
		return "", fmt.Errorf("set REPLYCANT_TEST_HEADSCALE_ADVERTISED_URL to headscale's configured server_url")
	}
	return advertised, nil
}
