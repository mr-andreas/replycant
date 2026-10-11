// Package tailnet is the server stack's client for the headscale control plane
// it is colocated with.
//
// headscale's database is a cache of what pubkeys/ in the repository already
// says, so everything here exists to keep that cache in line with git:
// minting single-use pre-auth keys for nodes git already authorizes (gitd's
// own node, and devices that ask hsproxy over mTLS), and expiring device nodes
// once their key leaves pubkeys/. Keys have to be minted on demand because
// headscale generates key material server-side and stores only a hash, so a
// key cannot be stored anywhere and replayed later.
//
// The headscale CLI is not used because it talks over a unix socket in
// headscale's own container. Reaching it would mean sharing that socket and
// granting full control-plane administration, when all the callers need is to
// create keys and expire nodes.
package tailnet

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// How long to wait on any single headscale call. Pairing happens with a person
// watching a spinner, so failing fast and letting them retry beats holding the
// request open.
const requestTimeout = 15 * time.Second

// How much of an error body to quote back. Enough to identify the failure,
// bounded so a misconfigured upstream returning HTML cannot flood the logs.
const maxErrorBodyBytes = 512

// The tag every paired device carries.
//
// The tailnet policy in docker-compose.yaml grants tag:device access to the
// server and says nothing about devices as destinations, which is what makes
// device-to-device traffic fail closed. Changing this name means changing the
// policy in the same commit, or every device joins with a tag no rule mentions.
const DeviceTag = "tag:device"

// How long a minted pre-auth key stays usable.
//
// Deliberately short. A key is a bearer credential for the tailnet, and the
// first device's passes through a QR code that could be photographed. Ten
// minutes covers scanning and joining; a node that misses the window simply
// asks for another.
const PreauthKeyTTL = 10 * time.Minute

// The tag gitd's own node carries. The policy names it as the only
// destination devices may reach, so gitd's key must carry it or no device can
// connect to the server.
const ServerTag = "tag:server"

// Where headscale is and who to mint keys for.
type Config struct {
	// Reached over the compose network, so plain http is expected here. The
	// control plane's public exposure is hsproxy's job, not gitd's.
	BaseURL string

	// A fixed API key. Mostly for tests; deployments use APIKeyFile.
	APIKey string

	// Where headscale-init writes the API key. Read on every call rather than
	// once, because headscale-init mints a new key after headscale's database
	// is wiped, and gitd and hsproxy keep running across that. Keeping it in
	// a file also keeps it out of flags and the process listing.
	APIKeyFile string

	// The headscale user every replycant device belongs to. Devices are not
	// separated by user because the tailnet is one household's, and per-user
	// separation would break MagicDNS between a user's own devices.
	UserName string

	// Overridable so tests can supply a transport; production uses a plain
	// client with the package timeout.
	HTTPClient *http.Client
}

// Talks to one headscale deployment on behalf of one user.
type Client struct {
	baseURL    string
	apiKey     string
	apiKeyFile string
	userName   string
	httpClient *http.Client

	// headscale addresses users by numeric id, but operators configure a name.
	// The mapping is fixed for the life of the deployment, so it is resolved
	// once and cached. A mutex rather than sync.Once because a failed lookup
	// must stay retryable: headscale may simply not be up yet.
	userIDMu sync.Mutex
	userID   string
}

// Validates the config up front so a deployment mistake surfaces at gitd
// startup rather than when the first device tries to pair.
func NewClient(config Config) (*Client, error) {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		return nil, errors.New("headscale base URL is required")
	}
	if _, err := url.Parse(baseURL); err != nil {
		return nil, fmt.Errorf("headscale base URL is not a valid URL: %w", err)
	}
	apiKey := strings.TrimSpace(config.APIKey)
	apiKeyFile := strings.TrimSpace(config.APIKeyFile)
	switch {
	case apiKey == "" && apiKeyFile == "":
		return nil, errors.New("headscale API key is required")
	case apiKey != "" && apiKeyFile != "":
		return nil, errors.New("set either a headscale API key or a key file, not both")
	}
	userName := strings.TrimSpace(config.UserName)
	if userName == "" {
		return nil, errors.New("headscale user name is required")
	}

	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: requestTimeout}
	}

	client := &Client{
		baseURL:    baseURL,
		apiKey:     apiKey,
		apiKeyFile: apiKeyFile,
		userName:   userName,
		httpClient: httpClient,
	}
	// Read once now so a headscale-init that never ran fails startup instead
	// of the first device that asks for a key.
	if _, err := client.currentAPIKey(); err != nil {
		return nil, err
	}
	return client, nil
}

func (c *Client) currentAPIKey() (string, error) {
	if c.apiKeyFile == "" {
		return c.apiKey, nil
	}
	raw, err := os.ReadFile(c.apiKeyFile)
	if err != nil {
		return "", fmt.Errorf("read headscale API key: %w", err)
	}
	key := strings.TrimSpace(string(raw))
	if key == "" {
		return "", fmt.Errorf("headscale API key file %s is empty", c.apiKeyFile)
	}
	return key, nil
}

// Creates a key a single node can use once to join the tailnet carrying tag.
//
// Single-use and short-lived by construction: the first device's key passes
// through a QR code someone could photograph, and every key is a bearer
// credential. A reusable or long-lived key would turn one intercepted key into
// indefinite tailnet access. Nothing needs a durable key anyway, because an
// authorized node can always ask for a fresh one.
func (c *Client) MintPreauthKey(ctx context.Context, tag string, validFor time.Duration) (string, error) {
	userID, err := c.resolveUserID(ctx)
	if err != nil {
		return "", err
	}

	request := map[string]any{
		"user":       userID,
		"reusable":   false,
		"ephemeral":  false,
		"expiration": time.Now().Add(validFor).UTC().Format(time.RFC3339),
		// The tailnet policy is expressed in tags, and a node can only be
		// tagged by the credential it registers with. Without this the device
		// joins untagged, the policy grants it nothing, and the failure
		// surfaces much later as an unreachable server.
		"aclTags": []string{tag},
	}

	var response struct {
		PreAuthKey struct {
			Key string `json:"key"`
		} `json:"preAuthKey"`
	}
	if err := c.do(ctx, http.MethodPost, "/api/v1/preauthkey", request, &response); err != nil {
		// A wiped headscale recreates the user, maybe under another id, so
		// the cached one is not trusted after a failure.
		c.forgetUserID()
		return "", fmt.Errorf("mint headscale pre-auth key: %w", err)
	}

	key := strings.TrimSpace(response.PreAuthKey.Key)
	if key == "" {
		return "", errors.New("headscale accepted the request but returned no pre-auth key")
	}
	return key, nil
}

// A registered tailnet node, reduced to what revocation needs to decide whether
// to expire it.
type Node struct {
	ID string `json:"id"`

	// Stable for the life of a device's tailnet state, and never reused,
	// which is why revocation identifies nodes by it rather than by ID:
	// headscale's IDs restart after its database is wiped.
	MachineKey string `json:"machineKey"`

	Name string   `json:"name"`
	Tags []string `json:"tags"`
}

// Reports whether the node carries tag, which is how device nodes are told
// apart from gitd's own node.
func (n Node) HasTag(tag string) bool {
	for _, candidate := range n.Tags {
		if candidate == tag {
			return true
		}
	}
	return false
}

// Lists every node headscale knows.
//
// Deliberately unfiltered by user: a tagged node loses its user association in
// headscale, and every replycant node is tagged, so a user filter would return
// nothing useful.
func (c *Client) ListNodes(ctx context.Context) ([]Node, error) {
	var response struct {
		Nodes []Node `json:"nodes"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/v1/node", nil, &response); err != nil {
		return nil, fmt.Errorf("list headscale nodes: %w", err)
	}
	return response.Nodes, nil
}

// Expires a node's key now, taking it off the tailnet until it logs in again.
//
// Expiry rather than deletion, because headscale 0.29 deletes a node without
// closing its live map session: a running device would never learn it was
// dropped and would sit on a dead tailnet until restarted. An expiry is pushed
// down that session, peers stop accepting the node, and the device itself
// moves to NeedsLogin, which every client watches for. Logging in again with
// a key reuses the same node, so expired nodes do not pile up; a revoked
// device's node stays listed as expired because hsproxy will not give it one.
func (c *Client) ExpireNode(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return errors.New("a headscale node id is required")
	}
	if err := c.do(ctx, http.MethodPost, "/api/v1/node/"+url.PathEscape(id)+"/expire", nil, nil); err != nil {
		return fmt.Errorf("expire headscale node %s: %w", id, err)
	}
	return nil
}

// Maps the configured user name to the numeric id headscale's API requires.
func (c *Client) resolveUserID(ctx context.Context) (string, error) {
	c.userIDMu.Lock()
	defer c.userIDMu.Unlock()

	if c.userID != "" {
		return c.userID, nil
	}

	var response struct {
		Users []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"users"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/v1/user", nil, &response); err != nil {
		return "", fmt.Errorf("list headscale users: %w", err)
	}
	for _, user := range response.Users {
		if user.Name == c.userName {
			c.userID = user.ID
			return c.userID, nil
		}
	}
	return "", fmt.Errorf("headscale has no user %q; headscale-init should have created it", c.userName)
}

func (c *Client) forgetUserID() {
	c.userIDMu.Lock()
	c.userID = ""
	c.userIDMu.Unlock()
}

// Issues one authenticated call, decoding a JSON response when one is wanted.
func (c *Client) do(ctx context.Context, method, path string, body any, out any) error {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request: %w", err)
		}
		payload = bytes.NewReader(encoded)
	}

	request, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, payload)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	apiKey, err := c.currentAPIKey()
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, maxErrorBodyBytes))
		return fmt.Errorf("headscale returned %d for %s %s: %s",
			response.StatusCode, method, path, strings.TrimSpace(string(detail)))
	}

	if out == nil {
		return nil
	}
	if err := json.NewDecoder(response.Body).Decode(out); err != nil {
		return fmt.Errorf("decode headscale response: %w", err)
	}
	return nil
}
