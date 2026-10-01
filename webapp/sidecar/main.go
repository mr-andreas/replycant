// Command replycant-tsnet joins the desktop app to the replycant tailnet.
//
// The desktop app cannot reach gitd directly any more: gitd publishes no host
// port and is reachable only from inside the tailnet. Electron is a Node
// process, and there is no usable userspace Tailscale implementation for Node,
// so this sidecar provides one and hands back a SOCKS5 proxy that Node's
// existing mTLS agents can dial through.
//
// It does two things. It runs the loopback shim from pkg/tailnetshim, which gives the
// Tailscale client a control-plane endpoint it will accept, and it runs a tsnet
// node whose built-in SOCKS5 proxy is published on loopback.
//
// Configuration arrives as JSON on stdin rather than as flags, because it
// contains the device's private key. Flags are visible in the process list on
// every platform the desktop app ships to.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetshim"
	"tailscale.com/tsnet"
)

// Bounds the tailnet join. The path runs through the hosted relay and the
// user's own machine, neither of which the sidecar controls, so an unbounded
// wait would present as the desktop app hanging on startup with no
// explanation. Electron restarts the sidecar, so failing is recoverable.
const joinTimeout = 2 * time.Minute

// Everything the sidecar needs, as delivered by Electron on stdin.
//
// All of it comes from the pairing record the device opened during onboarding,
// except the state directory, which Electron chooses inside its own userData
// so the node identity survives restarts.
type input struct {
	// host:port of the deployment's control plane.
	HeadscaleAddr string `json:"headscale_addr"`

	// Name verified against the control plane's certificate and sent as SNI,
	// which is what the reverse tunnel routes on.
	HeadscaleServerName string `json:"headscale_server_name"`

	// Where gitd relays control-plane traffic inside the tailnet, and the name
	// its certificate carries there. Installed on the shim once the node is up
	// so later control sessions stop crossing the hosted relay.
	//
	// Optional. Empty leaves the relay as the only path, which is what a
	// deployment that turned the in-tailnet relay off wants.
	GitdControlAddr       string `json:"gitd_control_addr"`
	GitdControlServerName string `json:"gitd_control_server_name"`

	// The deployment's CA. The only root the control-plane connection trusts.
	CAPEM string `json:"ca_pem"`

	// The device's mTLS identity, used both for the control-plane connection
	// and, by Node, for the connections that ride the tailnet afterwards.
	ClientCertPEM string `json:"client_cert_pem"`
	ClientKeyPEM  string `json:"client_key_pem"`

	// Single-use credential from the pairing record. Only needed for the
	// first join; afterwards the node re-authenticates from its own state.
	PreauthKey string `json:"preauth_key"`

	// Where tsnet keeps its node identity. Must persist across restarts, or
	// every launch consumes a new pre-auth key the device does not have.
	StateDir string `json:"state_dir"`

	// The node's name on the tailnet.
	Hostname string `json:"hostname"`
}

// What Electron needs in order to route traffic through the tailnet.
//
// Written as one JSON line on stdout once the node is up, so the parent can
// treat the sidecar as ready rather than polling or sleeping. Typed like every
// other stdout line, because status events follow it on the same stream.
type ready struct {
	Type          string   `json:"type"`
	SocksAddr     string   `json:"socks_addr"`
	SocksUsername string   `json:"socks_username"`
	SocksPassword string   `json:"socks_password"`
	TailnetIPs    []string `json:"tailnet_ips"`
	ControlURL    string   `json:"control_url"`
}

// tsnet's SOCKS5 listener always authenticates as this user, with the
// credential returned by Loopback as the password.
const socksUsername = "tsnet"

// Matches tsnet.Server.Dial. Named so the route derivation can be tested
// without standing up a real WireGuard node.
type dialFunc func(ctx context.Context, network, address string) (net.Conn, error)

func main() {
	// Logs go to stderr so stdout carries only the readiness line. Electron
	// parses stdout, and an interleaved log would break that.
	log.SetOutput(os.Stderr)
	log.SetFlags(0)
	log.SetPrefix("tsnet-sidecar: ")

	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	config, err := readInput(os.Stdin)
	if err != nil {
		return err
	}

	clientCert, err := tls.X509KeyPair([]byte(config.ClientCertPEM), []byte(config.ClientKeyPEM))
	if err != nil {
		return fmt.Errorf("the device certificate and key do not form a usable pair: %w", err)
	}

	controlPlane, err := tailnetshim.New(tailnetshim.Config{
		UpstreamAddr:       config.HeadscaleAddr,
		UpstreamServerName: config.HeadscaleServerName,
		CAPEM:              []byte(config.CAPEM),
		ClientCertificate:  clientCert,
		Logf:               log.Printf,
	})
	if err != nil {
		return err
	}
	if err := controlPlane.Start(); err != nil {
		return err
	}
	defer controlPlane.Close()

	// Signals rather than stdin closure, because Electron's child-process
	// teardown sends a signal and closing stdin is not reliable across
	// platforms.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go controlPlane.Serve(ctx)
	log.Printf("control plane %s fronted at %s", controlPlane.UpstreamServerName(), controlPlane.Addr())

	node, err := startNode(ctx, config, controlPlane.ControlURL())
	if err != nil {
		return err
	}
	defer node.Close()

	// Only now, because the node had to reach the control plane through the
	// relay before it could route anything at all. From here on the shim
	// prefers the in-tailnet path, so the relay is a bootstrap dependency
	// rather than something every session holds open.
	//
	// A failure here is logged rather than fatal: the relay path still works,
	// so a malformed address degrades to the previous behaviour.
	if route, ok := tailnetControlRoute(config, node.Dial); !ok {
		log.Printf("no in-tailnet control address configured; control traffic stays on the relay")
	} else if err := controlPlane.SetTailnetRoute(route); err != nil {
		log.Printf("in-tailnet control path unavailable, staying on the relay: %v", err)
	} else {
		log.Printf("control traffic will prefer %s over %s", route.Addr, config.HeadscaleAddr)
	}

	socksAddr, socksPassword, _, err := node.Loopback()
	if err != nil {
		return fmt.Errorf("expose the tailnet SOCKS5 proxy: %w", err)
	}

	if err := announce(os.Stdout, ready{
		SocksAddr:     socksAddr,
		SocksUsername: socksUsername,
		SocksPassword: socksPassword,
		TailnetIPs:    tailnetIPs(node),
		ControlURL:    controlPlane.ControlURL(),
	}); err != nil {
		return err
	}

	// Started only after readiness, so the parent reads the readiness line
	// first and is never handed a status event before it knows the sidecar is
	// up. Failing to obtain the client is not fatal: the tailnet works, the
	// desktop app just cannot show its state.
	if client, err := node.LocalClient(); err != nil {
		log.Printf("tailnet status is unavailable; the app will show no connection detail: %v", err)
	} else {
		go publishStatus(ctx, os.Stdout, statusPoller{
			Interval: statusInterval,
			Status:   client.Status,
			Route:    controlPlane.LastRoute,
		})
	}

	// The node and the shim only exist while this process does, so it stays
	// alive until asked to stop.
	<-ctx.Done()
	log.Printf("shutting down")
	return nil
}

// Derives the shim's in-tailnet route, reporting false when the deployment has
// not configured one.
//
// dial is tsnet's own dialer, because a tailnet name resolves only through the
// node's MagicDNS resolver and the address is only routable through its
// userspace WireGuard stack.
func tailnetControlRoute(config input, dial dialFunc) (tailnetshim.TailnetRoute, bool) {
	addr := strings.TrimSpace(config.GitdControlAddr)
	if addr == "" {
		return tailnetshim.TailnetRoute{}, false
	}

	serverName := strings.TrimSpace(config.GitdControlServerName)
	if serverName == "" {
		// The address is a MagicDNS name, so its host is also the name
		// hsproxy's certificate carries on this path.
		if host, _, err := net.SplitHostPort(addr); err == nil {
			serverName = host
		}
	}

	return tailnetshim.TailnetRoute{Addr: addr, ServerName: serverName, Dial: dial}, true
}

// Brings the tailnet node up, blocking until it has joined so a failure is
// reported here rather than surfacing later as unreachable hosts.
func startNode(ctx context.Context, config input, controlURL string) (*tsnet.Server, error) {
	if err := os.MkdirAll(config.StateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create tailnet state directory %q: %w", config.StateDir, err)
	}

	node := &tsnet.Server{
		Dir:        config.StateDir,
		Hostname:   config.Hostname,
		ControlURL: controlURL,
		AuthKey:    config.PreauthKey,
		UserLogf:   log.Printf,
		// Backend logs are dropped. magicsock and netcheck output would
		// otherwise dominate the desktop app's logs.
		Logf: func(string, ...any) {},
	}

	joinCtx, cancel := context.WithTimeout(ctx, joinTimeout)
	defer cancel()

	if _, err := node.Up(joinCtx); err != nil {
		_ = node.Close()
		return nil, fmt.Errorf("join the tailnet as %q: %w", config.Hostname, err)
	}
	return node, nil
}

// Reads and validates the configuration, so a missing field is named rather
// than surfacing as a confusing TLS or join failure later.
func readInput(reader io.Reader) (input, error) {
	raw, err := io.ReadAll(reader)
	if err != nil {
		return input{}, fmt.Errorf("read configuration from stdin: %w", err)
	}

	var config input
	if err := json.Unmarshal(raw, &config); err != nil {
		return input{}, fmt.Errorf("configuration on stdin is not valid JSON: %w", err)
	}

	required := map[string]string{
		"headscale_addr":  config.HeadscaleAddr,
		"ca_pem":          config.CAPEM,
		"client_cert_pem": config.ClientCertPEM,
		"client_key_pem":  config.ClientKeyPEM,
		"state_dir":       config.StateDir,
	}
	missing := make([]string, 0, len(required))
	for field, value := range required {
		if strings.TrimSpace(value) == "" {
			missing = append(missing, field)
		}
	}
	if len(missing) > 0 {
		return input{}, fmt.Errorf("configuration is missing %s", strings.Join(missing, ", "))
	}

	// A relative state directory would land wherever Electron happened to be
	// launched from, so the node identity would not survive a restart.
	if !filepath.IsAbs(config.StateDir) {
		return input{}, fmt.Errorf("state_dir must be an absolute path, got %q", config.StateDir)
	}

	if strings.TrimSpace(config.Hostname) == "" {
		return input{}, errors.New("configuration is missing hostname")
	}
	return config, nil
}

// Emits the readiness line the parent process waits for.
func announce(writer io.Writer, message ready) error {
	message.Type = readyEventType
	return emit(writer, message)
}

// Reports the addresses the node was assigned, for the desktop app's logs.
func tailnetIPs(node *tsnet.Server) []string {
	ip4, ip6 := node.TailscaleIPs()
	var addrs []string
	if ip4.IsValid() {
		addrs = append(addrs, ip4.String())
	}
	if ip6.IsValid() {
		addrs = append(addrs, ip6.String())
	}
	return addrs
}
