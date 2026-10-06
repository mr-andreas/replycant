package tsnetserve

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Tailnet misconfiguration has to fail at startup. If it surfaced later, gitd
// would be running with no reachable listener and look like a client problem.
func TestConfigValidate(t *testing.T) {
	cases := []struct {
		name       string
		config     Config
		wantErrHas string
	}{
		{
			name:       "config requires a state directory",
			config:     Config{Hostname: "gitd", ControlURL: "https://hs.example"},
			wantErrHas: "state directory",
		},
		{
			name:       "config requires a control url",
			config:     Config{Dir: "/state", Hostname: "gitd"},
			wantErrHas: "control URL",
		},
		{
			name:       "config requires a hostname",
			config:     Config{Dir: "/state", ControlURL: "https://hs.example"},
			wantErrHas: "hostname",
		},
		{
			name:       "control url must be a url",
			config:     Config{Dir: "/state", Hostname: "gitd", ControlURL: "hs.example:8443"},
			wantErrHas: "control URL",
		},
		{
			name:   "plain http control url is allowed",
			config: Config{Dir: "/state", Hostname: "gitd", ControlURL: "http://127.0.0.1:9999"},
		},
		{
			name:   "complete config validates",
			config: Config{Dir: "/state", Hostname: "gitd", ControlURL: "https://hs.example"},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			err := testCase.config.Validate()
			if testCase.wantErrHas == "" {
				if err != nil {
					t.Fatalf("expected no error, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected an error mentioning %q", testCase.wantErrHas)
			}
			if !strings.Contains(err.Error(), testCase.wantErrHas) {
				t.Fatalf("expected error mentioning %q, got %v", testCase.wantErrHas, err)
			}
		})
	}
}

// gitd has no stored key any more. Without a minter its node could never
// rejoin after headscale loses its state, and would wait for an interactive
// login nobody is watching for, so Start refuses before touching the network.
func TestStartRequiresAKeyMinter(t *testing.T) {
	_, err := Start(context.Background(), Config{
		Dir:        t.TempDir(),
		Hostname:   "gitd",
		ControlURL: "http://127.0.0.1:9",
	})
	if err == nil || !strings.Contains(err.Error(), "minter") {
		t.Fatalf("expected a missing minter to be rejected, got %v", err)
	}
}

// gitd's node gets its key before tsnet starts, because a node that has never
// logged in cannot be handed a key afterwards. Without a key there is no way
// to join, so a failed mint has to stop startup before any node state is
// written rather than leave a node waiting for a login that never comes.
func TestStartFailsBeforeTheNodeStartsWhenNoKeyCanBeMinted(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := Start(ctx, Config{
		Dir:        dir,
		Hostname:   "gitd",
		ControlURL: "http://127.0.0.1:9",
		Mint: func(context.Context) (string, error) {
			return "", errors.New("headscale API unreachable")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "headscale API unreachable") {
		t.Fatalf("expected the mint failure to fail Start, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "tailscaled.state")); !errors.Is(statErr, os.ErrNotExist) {
		t.Errorf("no tsnet state may be written when no key could be minted, stat: %v", statErr)
	}
}
