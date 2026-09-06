//go:build integration

package tailnet_test

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/server/tailnet"
)

// Mints a real pre-auth key against a running headscale.
//
// The unit tests pin the request and response shapes against a fake, which
// catches drift in our own code but not a headscale upgrade that changes the
// API. This test is what proves the shapes are still right, and that the API
// key headscale-init writes is actually accepted.
//
// It also guards the tailnet policy without asserting anything about it:
// headscale rejects a key requesting an ACL tag that no tagOwners entry
// claims, so a policy that failed to load or that dropped tag:device shows up
// here as a failed mint.
//
// Skipped unless a headscale is pointed at, so `make test` stays fast.
func TestMintsAgainstRealHeadscale(t *testing.T) {
	baseURL := strings.TrimSpace(os.Getenv("REPLYCANT_TEST_HEADSCALE_API_URL"))
	apiKeyFile := strings.TrimSpace(os.Getenv("REPLYCANT_TEST_HEADSCALE_APIKEY_FILE"))
	if baseURL == "" || apiKeyFile == "" {
		t.Skip("set REPLYCANT_TEST_HEADSCALE_API_URL and REPLYCANT_TEST_HEADSCALE_APIKEY_FILE to run")
	}

	apiKey, err := os.ReadFile(apiKeyFile)
	if err != nil {
		t.Fatalf("read the API key headscale-init wrote: %v", err)
	}

	client, err := tailnet.NewClient(tailnet.Config{
		BaseURL:  baseURL,
		APIKey:   strings.TrimSpace(string(apiKey)),
		UserName: "replycant",
	})
	if err != nil {
		t.Fatalf("build client: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	key, err := client.MintPreauthKey(ctx, 10*time.Minute)
	if err != nil {
		t.Fatalf("headscale must accept the minting request: %v", err)
	}
	if strings.TrimSpace(key) == "" {
		t.Fatal("headscale must return a usable pre-auth key")
	}
	// Only the shape is asserted, never the value, so a failure log cannot
	// leak a live credential.
	t.Logf("minted a pre-auth key of %d characters", len(key))

	// Two mints in a row must produce different keys. A cached or reused key
	// would mean two devices sharing one single-use credential, so the second
	// device would fail to join for reasons that look unrelated.
	second, err := client.MintPreauthKey(ctx, 10*time.Minute)
	if err != nil {
		t.Fatalf("a second mint must also succeed: %v", err)
	}
	if second == key {
		t.Error("each pairing must get its own key")
	}
}
