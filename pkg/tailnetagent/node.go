package tailnetagent

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/pkg/tailnetlogin"
	"github.com/mr-andreas/replycant/pkg/tailnetshim"
	"tailscale.com/tsnet"
)

// joinTimeout bounds the first control session. It crosses the hosted relay
// and the user's machine, neither of which this process controls, so an
// unbounded wait would look like git hanging with no explanation.
const joinTimeout = 2 * time.Minute

// Run joins the tailnet described by cfg and serves the repository proxy
// until the process is asked to stop or the proxy goes idle.
func Run(ctx context.Context, cfg StartConfig) error {
	if _, err := encodeStartConfig(cfg); err != nil {
		return err
	}
	clientCert, err := tls.X509KeyPair([]byte(cfg.ClientCertPEM), []byte(cfg.ClientKeyPEM))
	if err != nil {
		return fmt.Errorf("the device certificate and key do not form a usable pair: %w", err)
	}

	logger := log.New(os.Stderr, "tailnet-agent: ", 0)
	controlPlane, err := tailnetshim.New(tailnetshim.Config{
		UpstreamAddr:       cfg.HeadscaleAddr,
		UpstreamServerName: cfg.HeadscaleServerName,
		CAPEM:              []byte(cfg.CAPEM),
		ClientCertificate:  clientCert,
		Logf:               logger.Printf,
	})
	if err != nil {
		return err
	}
	if err := controlPlane.Start(); err != nil {
		return err
	}
	defer controlPlane.Close()

	go controlPlane.Serve(ctx)

	node, err := startNode(ctx, cfg, controlPlane, logger.Printf)
	if err != nil {
		return err
	}
	defer node.Close()

	// The first control session had to use the relay, because the node could
	// not route anywhere until it was up. Later sessions prefer gitd's
	// in-tailnet splice so the relay is only a bootstrap path.
	route := tailnetshim.TailnetRoute{
		Addr:       tailnetaddr.ControlAddr(),
		ServerName: tailnetaddr.GitdHost,
		Dial:       node.Dial,
	}
	if err := controlPlane.SetTailnetRoute(route); err != nil {
		logger.Printf("in-tailnet control path unavailable, staying on the relay: %v", err)
	}

	server := &Server{Dir: Dir(cfg.GitDir), Dial: node.Dial}
	return server.Run(ctx)
}

// startNode blocks until the node has joined so a failure is reported here
// rather than later as an unreachable gitd.
//
// The node is kept logged in for the agent's lifetime: whenever headscale does
// not know it, on first join or after headscale lost its state, it mints a key
// from hsproxy with the device certificate and logs in again.
func startNode(ctx context.Context, cfg StartConfig, controlPlane *tailnetshim.Shim, logf func(string, ...any)) (*tsnet.Server, error) {
	dir := statePath(Dir(cfg.GitDir))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create tailnet state directory: %w", err)
	}
	node := &tsnet.Server{
		Dir:        dir,
		Hostname:   cfg.Hostname,
		ControlURL: controlPlane.ControlURL(),
		UserLogf:   log.Printf,
		Logf:       func(string, ...any) {},
	}
	if err := tailnetlogin.Keep(ctx, node, controlPlane.MintPreauthKey, logf); err != nil {
		_ = node.Close()
		return nil, err
	}
	joinCtx, cancel := context.WithTimeout(ctx, joinTimeout)
	defer cancel()
	if _, err := node.Up(joinCtx); err != nil {
		_ = node.Close()
		return nil, fmt.Errorf("join the tailnet as %q: %w", cfg.Hostname, err)
	}
	return node, nil
}
