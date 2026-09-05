// Package tailnet is gitd's client for the headscale control plane it is
// colocated with.
//
// gitd needs this for one job: minting the single-use pre-auth key that a
// pairing device uses to join the tailnet. The key cannot come from the QR code
// because headscale generates key material server-side and stores only a hash,
// so there is no way for a device to propose a key of its own. gitd is
// therefore the component that asks headscale for a key on the device's behalf
// and delivers it inside the sealed pairing record.
//
// The headscale CLI is not used because it talks over a unix socket in
// headscale's own container. Reaching it would mean sharing that socket with
// gitd and granting gitd full control-plane administration, when all it needs
// is to create keys for one user.
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

// Where headscale is and who to mint keys for.
type Config struct {
	// Reached over the compose network, so plain http is expected here. The
	// control plane's public exposure is hsproxy's job, not gitd's.
	BaseURL string

	// Minted by headscale-init and read from disk by the caller, so it is
	// never present in gitd's flags or process listing.
	APIKey string

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
	if apiKey == "" {
		return nil, errors.New("headscale API key is required")
	}
	userName := strings.TrimSpace(config.UserName)
	if userName == "" {
		return nil, errors.New("headscale user name is required")
	}

	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: requestTimeout}
	}

	return &Client{
		baseURL:    baseURL,
		apiKey:     apiKey,
		userName:   userName,
		httpClient: httpClient,
	}, nil
}

// Creates a key a single device can use once to join the tailnet.
//
// Single-use and short-lived by construction: the key travels to a device that
// has not been trusted with anything yet, over a path that includes a QR code
// someone could photograph. A reusable or long-lived key would turn one
// intercepted pairing into indefinite tailnet access.
func (c *Client) MintPreauthKey(ctx context.Context, validFor time.Duration) (string, error) {
	userID, err := c.resolveUserID(ctx)
	if err != nil {
		return "", err
	}

	request := map[string]any{
		"user":       userID,
		"reusable":   false,
		"ephemeral":  false,
		"expiration": time.Now().Add(validFor).UTC().Format(time.RFC3339),
	}

	var response struct {
		PreAuthKey struct {
			Key string `json:"key"`
		} `json:"preAuthKey"`
	}
	if err := c.do(ctx, http.MethodPost, "/api/v1/preauthkey", request, &response); err != nil {
		return "", fmt.Errorf("mint headscale pre-auth key: %w", err)
	}

	key := strings.TrimSpace(response.PreAuthKey.Key)
	if key == "" {
		return "", errors.New("headscale accepted the request but returned no pre-auth key")
	}
	return key, nil
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
	request.Header.Set("Authorization", "Bearer "+c.apiKey)
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
