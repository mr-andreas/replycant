package tailnet

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Stands in for headscale, asserting on what the client sends and replaying the
// response shapes captured from headscale 0.29.3. Using a fake rather than a
// real headscale keeps these tests fast enough to run on every commit; the
// shapes themselves are pinned by TestRequestMatchesHeadscaleAPIShape below.
type fakeHeadscale struct {
	apiKey string

	// Handlers run on separate goroutines, and one test mints concurrently on
	// purpose, so every field below is guarded.
	mu              sync.Mutex
	userRequests    int
	preauthRequests int
	lastPreauthBody map[string]any
	lastAuthHeader  string
	userResponse    string
	preauthResponse string
	preauthStatus   int
	userStatus      int
	server          *httptest.Server
}

// Reads a guarded field. Tests inspect the fake only after the calls they are
// asserting on have returned, so a plain lock is enough.
func (f *fakeHeadscale) snapshot() (userRequests, preauthRequests int, authHeader string, preauthBody map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.userRequests, f.preauthRequests, f.lastAuthHeader, f.lastPreauthBody
}

func (f *fakeHeadscale) setUserStatus(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.userStatus = status
}

func (f *fakeHeadscale) setUserResponse(body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.userResponse = body
}

func (f *fakeHeadscale) setPreauthResponse(body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.preauthResponse = body
}

func newFakeHeadscale(t *testing.T) *fakeHeadscale {
	t.Helper()
	fake := &fakeHeadscale{
		apiKey: "test-api-key",
		userResponse: `{"users":[{"id":"1","name":"replycant"},` +
			`{"id":"2","name":"someone-else"}]}`,
		preauthResponse: `{"preAuthKey":{"id":"7","key":"hskey-auth-minted","user":{"id":"1","name":"replycant"}}}`,
		userStatus:      http.StatusOK,
		preauthStatus:   http.StatusOK,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/user", func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.userRequests++
		fake.lastAuthHeader = r.Header.Get("Authorization")
		status, body := fake.userStatus, fake.userResponse
		fake.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("/api/v1/preauthkey", func(w http.ResponseWriter, r *http.Request) {
		requestBody, _ := io.ReadAll(r.Body)
		decoded := map[string]any{}
		_ = json.Unmarshal(requestBody, &decoded)

		fake.mu.Lock()
		fake.preauthRequests++
		fake.lastAuthHeader = r.Header.Get("Authorization")
		fake.lastPreauthBody = decoded
		status, body := fake.preauthStatus, fake.preauthResponse
		fake.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	})
	fake.server = httptest.NewServer(mux)
	t.Cleanup(fake.server.Close)
	return fake
}

func newTestClient(t *testing.T, fake *fakeHeadscale) *Client {
	t.Helper()
	client, err := NewClient(Config{
		BaseURL:  fake.server.URL,
		APIKey:   fake.apiKey,
		UserName: "replycant",
	})
	if err != nil {
		t.Fatalf("a complete config must build a client: %v", err)
	}
	return client
}

// A minted key is the only thing a pairing device can use to join, so the
// client must return it verbatim rather than any of the surrounding metadata.
func TestMintPreauthKeyReturnsTheKey(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	key, err := client.MintPreauthKey(context.Background(), time.Hour)
	if err != nil {
		t.Fatalf("minting must succeed against a healthy headscale: %v", err)
	}
	if key != "hskey-auth-minted" {
		t.Fatalf("expected the key from the response, got %q", key)
	}
}

// The key travels to a device that has not yet been trusted with anything, so
// it must be single-use. A reusable key would let anyone who intercepted one
// pairing QR join the tailnet repeatedly.
func TestMintedKeysAreSingleUseAndExpiring(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), 30*time.Minute); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}

	_, _, _, body := fake.snapshot()
	if reusable, ok := body["reusable"].(bool); !ok || reusable {
		t.Errorf("minted keys must not be reusable, got %v", body["reusable"])
	}
	rawExpiration, ok := body["expiration"].(string)
	if !ok {
		t.Fatalf("minted keys must carry an expiration, got %v", body["expiration"])
	}
	expiration, err := time.Parse(time.RFC3339, rawExpiration)
	if err != nil {
		t.Fatalf("expiration must be RFC3339 so headscale can parse it: %v", err)
	}
	if until := time.Until(expiration); until > 31*time.Minute || until < 29*time.Minute {
		t.Errorf("expiration must reflect the requested TTL, got %v from now", until)
	}
}

// Ephemeral nodes are removed from the tailnet when they disconnect. Devices
// are expected to come and go, so an ephemeral registration would silently
// unpair a phone every time it lost connectivity.
func TestMintedKeysAreNotEphemeral(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}
	_, _, _, body := fake.snapshot()
	if ephemeral, ok := body["ephemeral"].(bool); !ok || ephemeral {
		t.Errorf("minted keys must not be ephemeral, got %v", body["ephemeral"])
	}
}

// Every device joins tagged, because the tailnet policy is written in terms of
// tags: tag:device is what grants access to the server, and its absence is
// what keeps devices from reaching each other. The tag has to be attached to
// the credential, since a node cannot claim a tag for itself after the fact.
func TestMintedKeysTagTheDevice(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}

	_, _, _, body := fake.snapshot()
	tags, ok := body["aclTags"].([]any)
	if !ok {
		t.Fatalf("minted keys must carry aclTags, got %v", body["aclTags"])
	}
	if len(tags) != 1 || tags[0] != "tag:device" {
		t.Errorf("minted keys must carry exactly tag:device, got %v", tags)
	}
}

// headscale addresses users by numeric id, not name, so the client has to
// resolve the configured name first. Getting this wrong would mint keys for
// whichever user happened to be first in the list.
func TestUserNameIsResolvedToItsID(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}
	_, _, _, body := fake.snapshot()
	if got := body["user"]; got != "1" {
		t.Errorf("expected the resolved id of the replycant user, got %v", got)
	}
}

// Resolving the user costs a round trip that would otherwise repeat on every
// pairing. The id is stable for the life of the deployment, so caching it is
// safe and keeps pairing latency down.
func TestResolvedUserIDIsCached(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	for range 3 {
		if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
			t.Fatalf("minting must succeed: %v", err)
		}
	}
	userRequests, preauthRequests, _, _ := fake.snapshot()
	if userRequests != 1 {
		t.Errorf("the user lookup should happen once, happened %d times", userRequests)
	}
	if preauthRequests != 3 {
		t.Errorf("every mint needs its own key, got %d requests", preauthRequests)
	}
}

// Two devices can be paired at once, and both paths mint a key. The cached
// user lookup must therefore be safe to reach concurrently. Run with -race,
// this is what catches an unsynchronised cache.
func TestConcurrentMintsAreSafe(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	const minters = 8
	errs := make(chan error, minters)
	for range minters {
		go func() {
			_, err := client.MintPreauthKey(context.Background(), time.Hour)
			errs <- err
		}()
	}
	for range minters {
		if err := <-errs; err != nil {
			t.Errorf("concurrent minting must succeed: %v", err)
		}
	}
	_, preauthRequests, _, _ := fake.snapshot()
	if preauthRequests != minters {
		t.Errorf("each mint needs its own key, got %d", preauthRequests)
	}
}

// A headscale that is still starting up returns errors for a while. Caching
// that failure would leave gitd permanently unable to pair, so a later attempt
// has to be allowed to retry the lookup.
func TestFailedUserLookupIsRetried(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setUserStatus(http.StatusServiceUnavailable)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err == nil {
		t.Fatal("the first attempt must fail while headscale is unavailable")
	}

	fake.setUserStatus(http.StatusOK)
	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("a later attempt must succeed once headscale recovers: %v", err)
	}
}

// A missing user is a deployment error, not a transient failure. Saying so
// plainly avoids sending an operator to look at the network.
func TestUnknownUserIsReportedClearly(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setUserResponse(`{"users":[{"id":"4","name":"other"}]}`)
	client := newTestClient(t, fake)

	_, err := client.MintPreauthKey(context.Background(), time.Hour)
	if err == nil {
		t.Fatal("minting must fail when the configured user does not exist")
	}
	if !strings.Contains(err.Error(), "replycant") {
		t.Errorf("the error should name the user that was not found, got %v", err)
	}
}

// The API key authorizes every call. Sending it in the wrong header or scheme
// would make headscale respond as if the deployment were unconfigured.
func TestAPIKeyIsSentAsABearerToken(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}
	_, _, authHeader, _ := fake.snapshot()
	if authHeader != "Bearer test-api-key" {
		t.Errorf("expected a bearer token, got %q", authHeader)
	}
}

// A rejected API key must not look like a missing key, because the remedies
// differ: one is a rotation, the other is a headscale-init that never ran.
func TestRejectedAPIKeySurfacesTheStatus(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setUserStatus(http.StatusUnauthorized)
	fake.setUserResponse(`{"message":"unauthorized"}`)
	client := newTestClient(t, fake)

	_, err := client.MintPreauthKey(context.Background(), time.Hour)
	if err == nil {
		t.Fatal("minting must fail when headscale rejects the API key")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("the error should carry the status so the cause is identifiable, got %v", err)
	}
}

// A response headscale accepted but that carries no key would otherwise be
// sealed into a pairing record and fail on the device, far from the cause.
func TestEmptyMintedKeyIsRejected(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setPreauthResponse(`{"preAuthKey":{"id":"7","key":""}}`)
	client := newTestClient(t, fake)

	_, err := client.MintPreauthKey(context.Background(), time.Hour)
	if err == nil {
		t.Fatal("minting must fail when headscale returns no key")
	}
}

// Pairing has a person waiting on it, so a stalled headscale must surface as a
// failure rather than holding the request open indefinitely.
func TestContextCancellationAborts(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := client.MintPreauthKey(ctx, time.Hour)
	if err == nil {
		t.Fatal("minting must fail once the context is cancelled")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("the cancellation should be preserved for callers to inspect, got %v", err)
	}
}

// Each field is required to reach headscale at all, so an incomplete config is
// caught at construction instead of at the first pairing attempt.
func TestNewClientRejectsIncompleteConfig(t *testing.T) {
	complete := Config{BaseURL: "http://headscale:8080", APIKey: "k", UserName: "replycant"}

	for _, testCase := range []struct {
		name   string
		mutate func(*Config)
	}{
		{"no base URL", func(c *Config) { c.BaseURL = "" }},
		{"no API key", func(c *Config) { c.APIKey = "" }},
		{"no user name", func(c *Config) { c.UserName = "" }},
		{"unparseable base URL", func(c *Config) { c.BaseURL = "http://[::1" }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			config := complete
			testCase.mutate(&config)
			if _, err := NewClient(config); err == nil {
				t.Fatal("an incomplete config must be rejected at construction")
			}
		})
	}
}

// A trailing slash on the configured URL is easy to introduce through compose
// interpolation and would produce a double-slashed path that headscale 404s.
func TestBaseURLTrailingSlashIsTolerated(t *testing.T) {
	fake := newFakeHeadscale(t)
	client, err := NewClient(Config{
		BaseURL:  fake.server.URL + "/",
		APIKey:   fake.apiKey,
		UserName: "replycant",
	})
	if err != nil {
		t.Fatalf("a trailing slash must not be a configuration error: %v", err)
	}
	if _, err := client.MintPreauthKey(context.Background(), time.Hour); err != nil {
		t.Fatalf("minting must still work: %v", err)
	}
}

// Pins the request and response shapes to what headscale 0.29.3 actually
// produced when probed by hand. If a headscale upgrade changes them, this test
// is the one that should fail, rather than pairing breaking in production.
func TestRequestMatchesHeadscaleAPIShape(t *testing.T) {
	fake := newFakeHeadscale(t)
	// Captured verbatim from headscale 0.29.3, which pretty-prints and returns
	// numeric ids as strings.
	fake.setUserResponse(`{"users":[{"id":"1", "name":"replycant", ` +
		`"createdAt":"2026-09-05T20:33:41.005813715Z", "displayName":"", "email":"", ` +
		`"providerId":"", "provider":"", "profilePicUrl":""}]}`)
	fake.setPreauthResponse(`{"preAuthKey":{"user":{"id":"1", "name":"replycant"}, "id":"3", ` +
		`"key":"nodekey-shaped-value", "reusable":false, "ephemeral":false, "used":false, ` +
		`"expiration":"2026-09-06T12:00:00Z", "createdAt":"2026-09-05T20:40:16.994579843Z", "aclTags":[]}}`)
	client := newTestClient(t, fake)

	key, err := client.MintPreauthKey(context.Background(), time.Hour)
	if err != nil {
		t.Fatalf("the real headscale response shape must parse: %v", err)
	}
	if key != "nodekey-shaped-value" {
		t.Fatalf("expected the key field, got %q", key)
	}

	_, _, _, body := fake.snapshot()
	for _, field := range []string{"user", "reusable", "ephemeral", "expiration"} {
		if _, present := body[field]; !present {
			t.Errorf("headscale requires %q in the request body", field)
		}
	}
}
