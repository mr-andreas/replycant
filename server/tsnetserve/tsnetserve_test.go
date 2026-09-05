package tsnetserve

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// An unset state directory is how operators opt out of the tailnet, so it must
// read as "disabled" rather than as a misconfiguration.
func TestConfigEnabled(t *testing.T) {
	if (Config{}).Enabled() {
		t.Fatal("an empty config must be disabled")
	}
	if !(Config{Dir: "/var/lib/replycant/tsnet"}).Enabled() {
		t.Fatal("a config with a state directory must be enabled")
	}
}

// Tailnet misconfiguration has to fail at startup. If it surfaced later, gitd
// would be running with no reachable listener and look like a client problem.
func TestConfigValidate(t *testing.T) {
	cases := []struct {
		name       string
		config     Config
		wantErrHas string
	}{
		{
			name:   "disabled config needs nothing",
			config: Config{},
		},
		{
			name:       "enabled config requires a control url",
			config:     Config{Dir: "/state", Hostname: "gitd"},
			wantErrHas: "control URL",
		},
		{
			name:       "enabled config requires a hostname",
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

// The pre-auth key is read from a file rather than a flag because gitd logs its
// whole parsed configuration at startup, and a flag value would also be visible
// in the process list.
func TestResolveAuthKeyReadsFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authkey")
	if err := os.WriteFile(path, []byte("  hskey-auth-abc-def\n\n"), 0o600); err != nil {
		t.Fatalf("write authkey: %v", err)
	}

	config := Config{Dir: "/state", Hostname: "gitd", ControlURL: "https://hs.example", AuthKeyFile: path}
	key, err := config.resolveAuthKey()
	if err != nil {
		t.Fatalf("resolve auth key: %v", err)
	}
	if key != "hskey-auth-abc-def" {
		t.Fatalf("expected surrounding whitespace to be trimmed, got %q", key)
	}
}

// A node with existing state re-authenticates from that state, so a missing key
// file is only fatal when it was explicitly configured.
func TestResolveAuthKeyWithoutFile(t *testing.T) {
	config := Config{Dir: "/state", Hostname: "gitd", ControlURL: "https://hs.example"}
	key, err := config.resolveAuthKey()
	if err != nil {
		t.Fatalf("an unset auth key file must not be an error: %v", err)
	}
	if key != "" {
		t.Fatalf("expected an empty key, got %q", key)
	}
}

// A configured-but-unreadable key file is a deployment mistake worth failing
// on, because the node would otherwise silently wait for interactive login
// that nobody is watching for.
func TestResolveAuthKeyMissingFileFails(t *testing.T) {
	config := Config{
		Dir:         "/state",
		Hostname:    "gitd",
		ControlURL:  "https://hs.example",
		AuthKeyFile: filepath.Join(t.TempDir(), "absent"),
	}
	if _, err := config.resolveAuthKey(); err == nil {
		t.Fatal("expected a missing auth key file to fail")
	}
}

// An empty key file is the shape a half-finished headscale-init run leaves
// behind, and it must not be mistaken for "no key configured".
func TestResolveAuthKeyEmptyFileFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authkey")
	if err := os.WriteFile(path, []byte("\n  \n"), 0o600); err != nil {
		t.Fatalf("write authkey: %v", err)
	}

	config := Config{Dir: "/state", Hostname: "gitd", ControlURL: "https://hs.example", AuthKeyFile: path}
	if _, err := config.resolveAuthKey(); err == nil {
		t.Fatal("expected an empty auth key file to fail")
	}
}
