package tailnet

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	nodesResponse   string
	nodesQuery      string
	deletedNodes    []string
	server          *httptest.Server
}

func (f *fakeHeadscale) setNodesResponse(body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nodesResponse = body
}

func (f *fakeHeadscale) deleted() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.deletedNodes...)
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

func (f *fakeHeadscale) setPreauthStatus(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.preauthStatus = status
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
	mux.HandleFunc("GET /api/v1/node", func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.lastAuthHeader = r.Header.Get("Authorization")
		fake.nodesQuery = r.URL.RawQuery
		body := fake.nodesResponse
		fake.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("DELETE /api/v1/node/{id}", func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.lastAuthHeader = r.Header.Get("Authorization")
		fake.deletedNodes = append(fake.deletedNodes, r.PathValue("id"))
		fake.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{}`)
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

	key, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, 30*time.Minute); err != nil {
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

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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

// gitd mints its own credential through the same client, and the policy only
// lets devices reach nodes tagged tag:server. A server key minted with the
// device tag would put gitd on the tailnet where no device may reach it.
func TestMintedKeysCarryTheRequestedTag(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), ServerTag, time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}

	_, _, _, body := fake.snapshot()
	tags, ok := body["aclTags"].([]any)
	if !ok || len(tags) != 1 || tags[0] != "tag:server" {
		t.Errorf("a server key must carry exactly tag:server, got %v", body["aclTags"])
	}
}

// Revocation deletes device nodes by tag, so listing has to return every
// node with its id and tags. The list is not filtered by user because a
// tagged node loses its user association in headscale, so a user filter
// would hide exactly the nodes revocation is looking for.
func TestListNodesReturnsIDsAndTags(t *testing.T) {
	fake := newFakeHeadscale(t)
	// Shape from headscale 0.29.3's ListNodesResponse: uint64 ids are encoded
	// as strings by grpc-gateway, and tags replaced forcedTags/validTags.
	fake.setNodesResponse(`{"nodes":[` +
		`{"id":"1","name":"gitd","givenName":"gitd","tags":["tag:server"],"online":true},` +
		`{"id":"2","name":"phone","givenName":"phone","tags":["tag:device"],"online":false}]}`)
	client := newTestClient(t, fake)

	nodes, err := client.ListNodes(context.Background())
	if err != nil {
		t.Fatalf("listing must succeed against a healthy headscale: %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("expected both nodes, got %+v", nodes)
	}
	if nodes[0].ID != "1" || !nodes[0].HasTag(ServerTag) || nodes[0].HasTag(DeviceTag) {
		t.Errorf("first node must be gitd tagged tag:server only, got %+v", nodes[0])
	}
	if nodes[1].ID != "2" || !nodes[1].HasTag(DeviceTag) {
		t.Errorf("second node must be the device tagged tag:device, got %+v", nodes[1])
	}

	fake.mu.Lock()
	query := fake.nodesQuery
	fake.mu.Unlock()
	if query != "" {
		t.Errorf("nodes must be listed without a user filter, got query %q", query)
	}
}

// Deleting a node is what actually removes a revoked device's netmap entry
// and ends its control session, so the call must address the node by id.
func TestDeleteNodeAddressesTheNodeByID(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if err := client.DeleteNode(context.Background(), "42"); err != nil {
		t.Fatalf("deleting must succeed against a healthy headscale: %v", err)
	}
	if got := fake.deleted(); len(got) != 1 || got[0] != "42" {
		t.Errorf("expected node 42 to be deleted, got %v", got)
	}
	_, _, authHeader, _ := fake.snapshot()
	if authHeader != "Bearer test-api-key" {
		t.Errorf("node deletion must be authenticated, got %q", authHeader)
	}
}

// An empty id would turn the request into DELETE /api/v1/node/, which at best
// 404s and at worst matches a different route after a headscale upgrade.
func TestDeleteNodeRejectsAnEmptyID(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if err := client.DeleteNode(context.Background(), " "); err == nil {
		t.Fatal("an empty node id must be rejected before any request is sent")
	}
	if got := fake.deleted(); len(got) != 0 {
		t.Errorf("no request should reach headscale, got %v", got)
	}
}

// headscale addresses users by numeric id, not name, so the client has to
// resolve the configured name first. Getting this wrong would mint keys for
// whichever user happened to be first in the list.
func TestUserNameIsResolvedToItsID(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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
		if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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
			_, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err == nil {
		t.Fatal("the first attempt must fail while headscale is unavailable")
	}

	fake.setUserStatus(http.StatusOK)
	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
		t.Fatalf("a later attempt must succeed once headscale recovers: %v", err)
	}
}

// A missing user is a deployment error, not a transient failure. Saying so
// plainly avoids sending an operator to look at the network.
func TestUnknownUserIsReportedClearly(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setUserResponse(`{"users":[{"id":"4","name":"other"}]}`)
	client := newTestClient(t, fake)

	_, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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

	_, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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

	_, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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

	_, err := client.MintPreauthKey(ctx, DeviceTag, time.Hour)
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
		{"both an API key and a key file", func(c *Config) { c.APIKeyFile = "/data/tailnet/headscale.apikey" }},
		{"an unreadable key file", func(c *Config) {
			c.APIKey = ""
			c.APIKeyFile = "/nonexistent/headscale.apikey"
		}},
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

// headscale-init mints a new API key whenever headscale's database was wiped,
// because the old key died with it. gitd and hsproxy keep running across that
// restart, so they have to pick up the new key without being restarted.
func TestAPIKeyFileIsReadOnEveryCall(t *testing.T) {
	fake := newFakeHeadscale(t)
	fake.setNodesResponse(`{"nodes":[]}`)
	keyFile := filepath.Join(t.TempDir(), "headscale.apikey")
	if err := os.WriteFile(keyFile, []byte("first-key\n"), 0o600); err != nil {
		t.Fatalf("write API key: %v", err)
	}
	client, err := NewClient(Config{
		BaseURL:    fake.server.URL,
		APIKeyFile: keyFile,
		UserName:   "replycant",
	})
	if err != nil {
		t.Fatalf("a key file must be enough to build a client: %v", err)
	}

	if _, err := client.ListNodes(context.Background()); err != nil {
		t.Fatalf("list nodes: %v", err)
	}
	if _, _, header, _ := fake.snapshot(); header != "Bearer first-key" {
		t.Errorf("expected the key from the file, got %q", header)
	}

	if err := os.WriteFile(keyFile, []byte("second-key\n"), 0o600); err != nil {
		t.Fatalf("rewrite API key: %v", err)
	}
	if _, err := client.ListNodes(context.Background()); err != nil {
		t.Fatalf("list nodes: %v", err)
	}
	if _, _, header, _ := fake.snapshot(); header != "Bearer second-key" {
		t.Errorf("a rewritten key file must take effect on the next call, got %q", header)
	}
}

// A wiped headscale recreates the replycant user, possibly under another id.
// A cached id that no longer exists would make every later mint fail, so a
// failed mint has to look the user up again.
func TestUserIsLookedUpAgainAfterAFailedMint(t *testing.T) {
	fake := newFakeHeadscale(t)
	client := newTestClient(t, fake)

	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
		t.Fatalf("minting must succeed: %v", err)
	}
	fake.setPreauthStatus(http.StatusNotFound)
	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err == nil {
		t.Fatal("minting must fail while headscale rejects it")
	}
	fake.setPreauthStatus(http.StatusOK)
	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
		t.Fatalf("minting must recover: %v", err)
	}

	if userRequests, _, _, _ := fake.snapshot(); userRequests != 2 {
		t.Errorf("the user must be looked up again after a failed mint, got %d lookups", userRequests)
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
	if _, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour); err != nil {
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

	key, err := client.MintPreauthKey(context.Background(), DeviceTag, time.Hour)
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
