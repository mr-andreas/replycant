// Package tailnetnode brings a tsnet node onto the replycant tailnet and keeps
// it there.
//
// gitd, the desktop sidecar and the CLI agent all run a userspace node that
// must hold its login for as long as the process lives: it gets a key before
// its first start, logs back in whenever headscale stops accepting it, and
// gives up on a join that cannot complete rather than hang. Doing that in one
// place keeps the three from drifting apart on details such as when a key is
// minted.
package tailnetnode

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/pkg/tailnetlogin"
	"github.com/mr-andreas/replycant/pkg/tailnetshim"
	"tailscale.com/tsnet"
)

// Bounds the join. It crosses the hosted relay and machines this process does
// not control, so an unbounded wait would look like a hang with no
// explanation. Every caller is restarted by its parent, so failing is
// recoverable.
const defaultJoinTimeout = 2 * time.Minute

// Describes one node.
type Config struct {
	// Where tsnet keeps the node identity. Must survive restarts, or every
	// start registers a new node.
	Dir string

	// The node's name on the tailnet.
	Hostname string

	// Where the node registers: headscale directly for gitd, a loopback
	// shim for devices.
	ControlURL string

	// Mints a single-use key whenever headscale does not know the node.
	Mint tailnetlogin.MintFunc

	// Optional key for the first login. gitd always holds one; devices leave
	// it empty and mint only if they have never logged in.
	AuthKey string

	// Optional. Defaults to two minutes.
	JoinTimeout time.Duration

	// Receives user-facing messages. Optional; defaults to the standard
	// logger. tsnet's verbose backend log is dropped.
	Logf func(format string, args ...any)
}

func (c Config) validate() error {
	switch {
	case strings.TrimSpace(c.Dir) == "":
		return errors.New("tailnetnode: a state directory is required")
	case strings.TrimSpace(c.Hostname) == "":
		return errors.New("tailnetnode: a hostname is required")
	case strings.TrimSpace(c.ControlURL) == "":
		return errors.New("tailnetnode: a control URL is required")
	case c.Mint == nil:
		return errors.New("tailnetnode: a key minter is required; without one a node " +
			"headscale forgot would wait for an interactive login nobody completes")
	}
	return nil
}

// A node that has joined. Embeds the tsnet server for dialing, listening and
// the local API; Close also stops the login keeper.
type Node struct {
	*tsnet.Server
	stopKeeping context.CancelFunc
}

// Shuts the node down and stops keeping it logged in.
func (n *Node) Close() error {
	n.stopKeeping()
	return n.Server.Close()
}

// Starts the node, keeps it logged in until ctx ends or Close is called, and
// blocks until it has joined so a failure is reported here rather than later
// as unreachable hosts.
func Start(ctx context.Context, config Config) (*Node, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(config.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("create tailnet state directory %q: %w", config.Dir, err)
	}
	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}
	joinTimeout := config.JoinTimeout
	if joinTimeout <= 0 {
		joinTimeout = defaultJoinTimeout
	}

	server := &tsnet.Server{
		Dir:        config.Dir,
		Hostname:   config.Hostname,
		ControlURL: config.ControlURL,
		AuthKey:    config.AuthKey,
		UserLogf:   logf,
		// magicsock and netcheck output would otherwise dominate every
		// caller's logs.
		Logf: func(string, ...any) {},
	}

	keepCtx, stopKeeping := context.WithCancel(ctx)
	// Not closed on failure: Keep fails before tsnet has started, and
	// closing a tsnet server that never started panics.
	if err := tailnetlogin.Keep(keepCtx, server, config.Mint, logf); err != nil {
		stopKeeping()
		return nil, err
	}

	joinCtx, cancelJoin := context.WithTimeout(ctx, joinTimeout)
	defer cancelJoin()
	if _, err := server.Up(joinCtx); err != nil {
		stopKeeping()
		_ = server.Close()
		return nil, fmt.Errorf("join the tailnet at %s as %q: %w", config.ControlURL, config.Hostname, err)
	}
	return &Node{Server: server, stopKeeping: stopKeeping}, nil
}

// Describes a device: the desktop sidecar or the CLI agent. Devices reach the
// control plane only through a loopback shim that pins the deployment CA and
// presents the device certificate, because tsnet can do neither itself.
type DeviceConfig struct {
	// hsproxy's host:port, and the name its certificate carries.
	HeadscaleAddr       string
	HeadscaleServerName string

	// The deployment CA, the only root the control connection trusts.
	CAPEM []byte

	// The device's mTLS identity.
	ClientCertificate tls.Certificate

	Dir      string
	Hostname string

	// Optional. Defaults to the standard logger.
	Logf func(format string, args ...any)
}

// A device node and the shim it registers through.
type Device struct {
	Node         *Node
	ControlPlane *tailnetshim.Shim
}

// Takes the node down, then the shim it reached the control plane through.
func (d *Device) Close() error {
	nodeErr := d.Node.Close()
	shimErr := d.ControlPlane.Close()
	return errors.Join(nodeErr, shimErr)
}

// Starts the shim and the node behind it, then points later control sessions
// at gitd's in-tailnet relay.
//
// The first session has to cross the hosted relay, because the node can route
// nothing until it is up. Preferring the in-tailnet path afterwards keeps the
// relay a bootstrap dependency rather than something every session holds
// open. A route that cannot be installed is logged rather than fatal: the
// relay path still works.
func StartDevice(ctx context.Context, config DeviceConfig) (*Device, error) {
	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}
	controlPlane, err := tailnetshim.New(tailnetshim.Config{
		UpstreamAddr:       config.HeadscaleAddr,
		UpstreamServerName: config.HeadscaleServerName,
		CAPEM:              config.CAPEM,
		ClientCertificate:  config.ClientCertificate,
		Logf:               logf,
	})
	if err != nil {
		return nil, err
	}
	if err := controlPlane.Start(); err != nil {
		return nil, err
	}
	go controlPlane.Serve(ctx)
	logf("control plane %s fronted at %s", controlPlane.UpstreamServerName(), controlPlane.Addr())

	node, err := Start(ctx, Config{
		Dir:        config.Dir,
		Hostname:   config.Hostname,
		ControlURL: controlPlane.ControlURL(),
		Mint:       controlPlane.MintPreauthKey,
		Logf:       logf,
	})
	if err != nil {
		_ = controlPlane.Close()
		return nil, err
	}

	route := tailnetshim.TailnetRoute{
		Addr:       tailnetaddr.ControlAddr(),
		ServerName: tailnetaddr.GitdHost,
		Dial:       node.Dial,
	}
	if err := controlPlane.SetTailnetRoute(route); err != nil {
		logf("in-tailnet control path unavailable, staying on the relay: %v", err)
	} else {
		logf("control traffic will prefer %s over %s", route.Addr, config.HeadscaleAddr)
	}
	return &Device{Node: node, ControlPlane: controlPlane}, nil
}
