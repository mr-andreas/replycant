package tailnetshim

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
)

// Bounds the key response. It is a short JSON object; anything larger is not
// hsproxy.
const maxKeyResponseBytes = 4096

// Asks hsproxy for a fresh single-use tailnet key for this device.
//
// headscale's state is a cache of pubkeys/, so it can forget a device at any
// time: after its database is wiped, or after a revocation sweep drops every
// device node. A device then needs a new key to log back in, and hsproxy hands
// one out to any certificate currently in pubkeys/. Asking costs nothing to an
// authorized device and gets a revoked one nowhere.
//
// The request rides the same mTLS session as control traffic, so it trusts
// only the deployment CA and goes through the hosted relay. The key is
// returned rather than stored: it is single-use and expires within minutes.
func (s *Shim) MintPreauthKey(ctx context.Context) (string, error) {
	client := &http.Client{
		Transport: &http.Transport{
			DialTLSContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				conn := s.dialControlPlane(ctx)
				if conn == nil {
					return nil, errors.New("the control plane is unreachable")
				}
				return conn, nil
			},
			DisableKeepAlives: true,
		},
		Timeout: s.dialTimeout,
	}

	url := "https://" + s.upstreamServerName + tailnetaddr.PreauthKeyPath
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return "", fmt.Errorf("shim: build key request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("shim: request a tailnet key: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxKeyResponseBytes))
	if err != nil {
		return "", fmt.Errorf("shim: read the tailnet key response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("shim: the control plane refused a tailnet key: %s", resp.Status)
	}

	var decoded struct {
		PreauthKey string `json:"preauth_key"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return "", fmt.Errorf("shim: the tailnet key response is not valid JSON: %w", err)
	}
	key := strings.TrimSpace(decoded.PreauthKey)
	if key == "" {
		return "", errors.New("shim: the tailnet key response carried no key")
	}
	return key, nil
}
