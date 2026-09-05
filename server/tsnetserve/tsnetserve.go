// Package tsnetserve joins a server process to the replycant tailnet and hands
// back listeners that only tailnet peers can reach.
//
// This exists so gitd can stop publishing a host port. Previously the mTLS Git
// listener had to be reachable on the LAN or through a forwarded router port,
// which forced users to expose a service to the internet to sync from outside
// their home. Binding the listener to a tsnet node instead means the only
// publicly reachable surface is the headscale control plane.
//
// tsnet is used in preference to a `tailscale` sidecar container because the
// sidecar approach needs NET_ADMIN and /dev/net/tun, and would make the whole
// compose stack require elevated privileges for one service's benefit.
package tsnetserve

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strings"

	"tailscale.com/tsnet"
)

// Describes how this process should appear on the tailnet.
//
// Dir doubles as the on/off switch: an empty Dir means "no tailnet", which is
// what integration tests and LAN-only deployments use. tsnet would otherwise
// pick a state directory under the user config dir, which is never what a
// containerised server wants.
type Config struct {
	Dir        string
	ControlURL string
	Hostname   string

	// Read from a file rather than passed inline because gitd logs its parsed
	// configuration at startup and flag values are visible in the process
	// list. Optional once the node has joined and has state on disk.
	AuthKeyFile string

	// Emits tsnet's user-facing messages (login URLs, state changes). Verbose
	// backend logging is intentionally discarded to keep gitd's output usable.
	Logf func(format string, args ...any)
}

// Reports whether a tailnet node should be started for this process.
func (c Config) Enabled() bool {
	return strings.TrimSpace(c.Dir) != ""
}

// Checks that an enabled config is complete and internally consistent, so a
// deployment mistake fails immediately instead of leaving gitd running with no
// listener anyone can reach.
func (c Config) Validate() error {
	if !c.Enabled() {
		return nil
	}
	if strings.TrimSpace(c.Hostname) == "" {
		return errors.New("tsnet hostname is required when a tsnet state directory is set")
	}

	rawControlURL := strings.TrimSpace(c.ControlURL)
	if rawControlURL == "" {
		return errors.New("tsnet control URL is required when a tsnet state directory is set")
	}
	parsed, err := url.Parse(rawControlURL)
	if err != nil {
		return fmt.Errorf("tsnet control URL is not a valid URL: %w", err)
	}
	// Plain http is legitimate here: clients reach headscale through a local
	// shim that terminates the end-to-end TLS itself, and the compose network
	// reaches it directly.
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return fmt.Errorf("tsnet control URL must be http or https, got %q", rawControlURL)
	}
	if parsed.Host == "" {
		return fmt.Errorf("tsnet control URL must include a host, got %q", rawControlURL)
	}
	return nil
}

// Loads the pre-auth key if one was configured. A configured-but-unusable file
// is fatal: without it the node waits for an interactive login that no one is
// watching for, which looks like a hang rather than a misconfiguration.
func (c Config) resolveAuthKey() (string, error) {
	path := strings.TrimSpace(c.AuthKeyFile)
	if path == "" {
		return "", nil
	}

	contents, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read tsnet auth key file %q: %w", path, err)
	}
	key := strings.TrimSpace(string(contents))
	if key == "" {
		return "", fmt.Errorf("tsnet auth key file %q is empty", path)
	}
	return key, nil
}

// A started tailnet node plus the listeners opened on it. Close tears down the
// node and every listener derived from it.
type Node struct {
	server *tsnet.Server
}

// Brings the node up and blocks until it has joined the tailnet, so callers can
// report a clear startup failure rather than serving on a listener that will
// never receive traffic.
//
// The context bounds the join. Registration traffic crosses the reverse tunnel
// and a relay that may not be up yet, so an unbounded wait here would present
// as gitd hanging at startup with no explanation.
func Start(ctx context.Context, config Config) (*Node, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	if !config.Enabled() {
		return nil, errors.New("tsnetserve: cannot start a disabled config")
	}

	authKey, err := config.resolveAuthKey()
	if err != nil {
		return nil, err
	}

	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}

	if err := os.MkdirAll(config.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("create tsnet state directory %q: %w", config.Dir, err)
	}

	server := &tsnet.Server{
		Dir:        config.Dir,
		Hostname:   config.Hostname,
		ControlURL: config.ControlURL,
		AuthKey:    authKey,
		UserLogf:   logf,
		// Verbose backend logs are dropped; magicsock and netcheck output
		// would otherwise dominate gitd's logs.
		Logf: func(string, ...any) {},
	}

	if _, err := server.Up(ctx); err != nil {
		_ = server.Close()
		return nil, fmt.Errorf("join tailnet at %s as %q: %w", config.ControlURL, config.Hostname, err)
	}

	return &Node{server: server}, nil
}

// Opens a listener reachable only from the tailnet.
func (n *Node) Listen(network, addr string) (net.Listener, error) {
	listener, err := n.server.Listen(network, addr)
	if err != nil {
		return nil, fmt.Errorf("listen on tailnet %s %s: %w", network, addr, err)
	}
	return listener, nil
}

// Reports the node's tailnet addresses so startup logs can tell an operator
// where the service actually became reachable.
func (n *Node) Addrs() []string {
	ip4, ip6 := n.server.TailscaleIPs()
	var addrs []string
	if ip4.IsValid() {
		addrs = append(addrs, ip4.String())
	}
	if ip6.IsValid() {
		addrs = append(addrs, ip6.String())
	}
	return addrs
}

// Shuts the node down, closing every listener opened on it.
func (n *Node) Close() error {
	return n.server.Close()
}
