// Command replycant-tsnet joins the desktop app to the replycant tailnet.
//
// The desktop app cannot reach gitd directly any more: gitd publishes no host
// port and is reachable only from inside the tailnet. Electron is a Node
// process, and there is no usable userspace Tailscale implementation for Node,
// so this sidecar provides one and hands back a SOCKS5 proxy that Node's
// existing mTLS agents can dial through.
//
// It starts a device node through pkg/tailnetnode, which fronts the control
// plane with a loopback shim the Tailscale client will accept, and publishes
// the node's built-in SOCKS5 proxy on loopback.
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
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/mr-andreas/replycant/pkg/tailnetnode"
)

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

	// The deployment's CA. The only root the control-plane connection trusts.
	CAPEM string `json:"ca_pem"`

	// The device's mTLS identity, used both for the control-plane connection
	// and, by Node, for the connections that ride the tailnet afterwards.
	ClientCertPEM string `json:"client_cert_pem"`
	ClientKeyPEM  string `json:"client_key_pem"`

	// Where tsnet keeps its node identity. Persisted so a restart rejoins as
	// the same node instead of registering a new one each launch.
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

	// Signals rather than stdin closure, because Electron's child-process
	// teardown sends a signal and closing stdin is not reliable across
	// platforms.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	device, err := tailnetnode.StartDevice(ctx, tailnetnode.DeviceConfig{
		HeadscaleAddr:       config.HeadscaleAddr,
		HeadscaleServerName: config.HeadscaleServerName,
		CAPEM:               []byte(config.CAPEM),
		ClientCertificate:   clientCert,
		Dir:                 config.StateDir,
		Hostname:            config.Hostname,
		Logf:                log.Printf,
	})
	if err != nil {
		return err
	}
	defer device.Close()
	node, controlPlane := device.Node, device.ControlPlane

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
func tailnetIPs(node *tailnetnode.Node) []string {
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
