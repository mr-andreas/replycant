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
	"net"
	"net/url"
	"strings"

	"github.com/mr-andreas/replycant/pkg/tailnetlogin"
	"github.com/mr-andreas/replycant/pkg/tailnetnode"
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

	// Obtains a fresh single-use key on every start, and whenever headscale
	// has lost its state. gitd mints its own over the headscale API, so no
	// key is ever stored on disk.
	Mint tailnetlogin.MintFunc

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

// A started tailnet node plus the listeners opened on it. Close tears down the
// node and every listener derived from it.
type Node struct {
	server *tailnetnode.Node
}

// Brings the node up and blocks until it has joined the tailnet, so callers can
// report a clear startup failure rather than serving on a listener that will
// never receive traffic.
//
// The context bounds minting the key. The join itself is bounded by
// tailnetnode, because registration crosses a relay that may not be up yet.
func Start(ctx context.Context, config Config) (*Node, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	if !config.Enabled() {
		return nil, errors.New("tsnetserve: cannot start a disabled config")
	}
	// Without one the node would wait for an interactive login no one is
	// watching for, which looks like a hang rather than a misconfiguration.
	if config.Mint == nil {
		return nil, errors.New("tsnetserve: a key minter is required")
	}

	// gitd is the first node on every tailnet and can always reach the
	// headscale API, so it takes a key on every start rather than working
	// out whether it has logged in before. A node that has ignores the key,
	// which then expires unused.
	authKey, err := config.Mint(ctx)
	if err != nil {
		return nil, fmt.Errorf("mint a tailnet key for %q: %w", config.Hostname, err)
	}

	// The node lives as long as gitd, not as long as the caller's context;
	// Close ends it.
	node, err := tailnetnode.Start(context.Background(), tailnetnode.Config{
		Dir:        config.Dir,
		Hostname:   config.Hostname,
		ControlURL: config.ControlURL,
		Mint:       config.Mint,
		AuthKey:    authKey,
		Logf:       config.Logf,
	})
	if err != nil {
		return nil, err
	}
	return &Node{server: node}, nil
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

// Resolves a tailnet peer address to the machine key of the node behind it,
// in headscale's "mkey:" form, so gitd can tell revocation which node a
// device's requests come from.
func (n *Node) WhoIs(ctx context.Context, remoteAddr string) (string, error) {
	client, err := n.server.LocalClient()
	if err != nil {
		return "", fmt.Errorf("tailnet local API: %w", err)
	}
	who, err := client.WhoIs(ctx, remoteAddr)
	if err != nil {
		return "", err
	}
	if who.Node == nil || who.Node.Machine.IsZero() {
		return "", fmt.Errorf("tailnet has no machine key for %s", remoteAddr)
	}
	return who.Node.Machine.String(), nil
}

// Shuts the node down, closing every listener opened on it.
func (n *Node) Close() error {
	return n.server.Close()
}
