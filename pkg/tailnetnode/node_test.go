package tailnetnode

import (
	"context"
	"crypto/tls"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Nothing listens here, so a join can only time out. That is enough to watch
// what Start does before and around the join without a control plane.
const unreachableControlURL = "http://127.0.0.1:9"

// A misconfigured node should fail at startup with the missing piece named,
// not later as a join that never completes.
func TestStartRejectsIncompleteConfig(t *testing.T) {
	mint := func(context.Context) (string, error) { return "key", nil }
	complete := Config{Dir: t.TempDir(), Hostname: "laptop", ControlURL: unreachableControlURL, Mint: mint}
	for _, testCase := range []struct {
		name   string
		mutate func(*Config)
		want   string
	}{
		{"no state directory", func(c *Config) { c.Dir = "" }, "state directory"},
		{"no hostname", func(c *Config) { c.Hostname = " " }, "hostname"},
		{"no control URL", func(c *Config) { c.ControlURL = "" }, "control URL"},
		{"no minter", func(c *Config) { c.Mint = nil }, "minter"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			config := complete
			testCase.mutate(&config)
			_, err := Start(context.Background(), config)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("expected an error naming the %s, got %v", testCase.want, err)
			}
		})
	}
}

// A node that has never logged in must get its key before tsnet starts, and
// must not burn a second one while that login is still in flight. A failed
// join then tears the node down instead of leaving it holding the key.
func TestStartMintsOnceForAFirstLogin(t *testing.T) {
	var mints atomic.Int32
	_, err := Start(context.Background(), Config{
		Dir:         t.TempDir(),
		Hostname:    "laptop",
		ControlURL:  unreachableControlURL,
		JoinTimeout: time.Second,
		Mint: func(context.Context) (string, error) {
			mints.Add(1)
			return "tskey-auth-test", nil
		},
	})
	if err == nil {
		t.Fatal("a join against an unreachable control plane must fail")
	}
	if got := mints.Load(); got != 1 {
		t.Errorf("a first login must mint exactly once, got %d", got)
	}
}

// gitd mints its own key on every start, because it can always reach the
// headscale API. A key it brings must be used as is, not replaced by a mint.
func TestStartUsesAKeyTheCallerAlreadyHas(t *testing.T) {
	var mints atomic.Int32
	_, err := Start(context.Background(), Config{
		Dir:         t.TempDir(),
		Hostname:    "gitd",
		ControlURL:  unreachableControlURL,
		AuthKey:     "tskey-auth-test",
		JoinTimeout: time.Second,
		Mint: func(context.Context) (string, error) {
			mints.Add(1)
			return "", errors.New("must not be called")
		},
	})
	if err == nil {
		t.Fatal("a join against an unreachable control plane must fail")
	}
	if got := mints.Load(); got != 0 {
		t.Errorf("a node handed a key must not mint another, got %d", got)
	}
}

// Without a key there is no way to join, so a failed mint has to stop startup
// at once, with the cause, rather than leave a node waiting for a login that
// never comes.
func TestStartFailsAtOnceWhenNoKeyCanBeMinted(t *testing.T) {
	started := time.Now()
	_, err := Start(context.Background(), Config{
		Dir:         t.TempDir(),
		Hostname:    "laptop",
		ControlURL:  unreachableControlURL,
		JoinTimeout: time.Minute,
		Mint: func(context.Context) (string, error) {
			return "", errors.New("hsproxy unreachable")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "hsproxy unreachable") {
		t.Fatalf("expected the mint failure to fail Start, got %v", err)
	}
	if elapsed := time.Since(started); elapsed > 10*time.Second {
		t.Errorf("a failed mint must not wait out the join, took %v", elapsed)
	}
}

// A device's control plane is only reachable through the shim, which needs
// the deployment CA and the device identity. A broken identity must fail
// before anything listens.
func TestStartDeviceRejectsAnUnusableCA(t *testing.T) {
	_, err := StartDevice(context.Background(), DeviceConfig{
		HeadscaleAddr:       "hs.example:443",
		HeadscaleServerName: "hs.example",
		CAPEM:               []byte("not a certificate"),
		ClientCertificate:   tls.Certificate{},
		Dir:                 t.TempDir(),
		Hostname:            "laptop",
	})
	if err == nil {
		t.Fatal("a CA that does not parse must be rejected")
	}
}
