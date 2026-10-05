package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/server/gitd"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/mr-andreas/replycant/server/gitd/caserver"
	"github.com/mr-andreas/replycant/server/gitd/lfs"
	"github.com/mr-andreas/replycant/server/pairing"
	"github.com/mr-andreas/replycant/server/tailnet"
	"github.com/mr-andreas/replycant/server/tcprelay"
	"github.com/mr-andreas/replycant/server/tsnetserve"
)

// Bounds how long gitd waits to join the tailnet before giving up. Joining
// depends on the reverse tunnel and relay being up, neither of which gitd
// controls, so an unbounded wait would present as a silent hang at startup.
// Restarting and retrying is the better failure mode: compose will do it.
const tsnetJoinTimeout = 2 * time.Minute

// CLI for gitd - Git HTTP server with mTLS authentication.
// Provides secure, certificate-based access to Git repositories.
type CLI struct {
	Repo string `required:"" help:"Path to Git repository (must be a bare repository)" type:"path"`
	Addr string `default:":8443" help:"Server address to listen on"`
	// CaAddr is independent of --addr so operators can remap onboarding
	// without moving the mTLS Git listener.
	CaAddr   string        `default:":8080" help:"CA distribution listen address"`
	Cert     string        `required:"" help:"Path to server TLS certificate" type:"path"`
	Key      string        `required:"" help:"Path to server TLS private key" type:"path"`
	CA       string        `required:"" help:"Path to CA certificate for client trust" type:"path"`
	CacheTTL time.Duration `default:"5m" help:"Cache TTL for authorized keys"`
	Check    bool          `help:"Run health check and exit"`
	Hostname string        `required:"" help:"Hostname to use for the server. Not used for anything, except for presenting a URL in the QR code scanned by apps."`
	LfsDir   string        `required:"" help:"Directory for the native file-backed LFS object store" type:"path"`

	// LfsInternalAddr is the plain-HTTP listener for compose-network readers
	// such as decryptd. Empty disables it so tests can omit the listener.
	LfsInternalAddr string `default:":8085" help:"Internal read-only LFS listen address (empty disables)"`

	DecryptdURL   string `required:"" help:"Internal decryptd URL proxied at /decryptd (full URL, e.g., http://decryptd:8084)"`
	TranscodedURL string `required:"" help:"Internal transcoded URL proxied at /transcoded (full URL, e.g., http://transcoded:8082)"`

	// Setting TsnetDir moves the mTLS Git listener onto the tailnet so no host
	// port has to be published. Left empty, gitd keeps its previous host-port
	// behaviour, which integration tests and LAN-only setups depend on.
	//
	// No key flag: gitd mints its own tailnet key over the headscale API
	// whenever headscale does not know its node, so a tailnet deployment
	// needs the --headscale-api-* flags as well.
	TsnetDir        string `help:"Directory for tailnet node state; set to serve the Git listener on the tailnet instead of a host port" type:"path"`
	TsnetControlURL string `help:"Headscale control URL for the tailnet node (e.g. http://headscale:8080)"`
	TsnetHostname   string `default:"gitd" help:"Hostname to register on the tailnet"`

	// The MagicDNS domain that headscale is configured with. Needed so the QR
	// and /config.json advertise a name tailnet peers can actually resolve.
	TailnetDomain string `help:"Headscale MagicDNS base domain, used to advertise the tailnet Git URL (e.g. replycant.internal)"`

	// A second way into the control plane, reachable only from inside the
	// tailnet. Devices bootstrap through the hosted relay because they have no
	// tailnet yet, but once they are members they should not keep depending on
	// a hosted service to stay connected. Splicing to hsproxy rather than to
	// headscale keeps the device's TLS session terminating at the same
	// authenticating front door on both paths.
	//
	// Empty --tailnet-control-addr turns it off, which is what an operator who
	// wants the relay to be the only way in would do.
	TailnetControlAddr     string `default:":8444" help:"Tailnet listen address for control-plane traffic; empty disables the tailnet control path"`
	TailnetControlUpstream string `default:"hsproxy:8443" help:"hsproxy address that tailnet control-plane traffic is spliced to"`

	// Cloud discovery. Without a discovery URL gitd runs in manual-exposure
	// mode, where the authorizing device shows the sealed record as a QR and
	// no record is ever published.
	DiscoveryURL        string `help:"Base URL of the discovery API; the pairing slot is prepended as a subdomain. Leave unset for manual-exposure mode"`
	HeadscaleAPIURL     string `name:"headscale-api-url" help:"Headscale API base URL used to mint keys for gitd and the first device, and to delete revoked device nodes (e.g. http://headscale:8080)"`
	HeadscaleAPIKeyFile string `help:"File containing the headscale API key; read from a file so it stays out of logs and the process list" type:"path"`
	HeadscaleUser       string `default:"replycant" help:"Headscale user that paired devices are registered under"`

	// The URL a pairing device should use to reach headscale. Distinct from
	// --headscale-api-url, which is the compose-internal address gitd itself
	// uses: devices reach the control plane through the tunnel or a forwarded
	// port, never over the compose network.
	HeadscaleClientURL string `help:"Headscale URL advertised to pairing devices (the tunnel hostname, or your own DNS name in manual mode)"`

	// Records which keys were authorized the last time headscale was
	// reconciled with pubkeys/, so a removal can be told apart from a
	// restart. Lives in gitd's own writable state, not in the read-only
	// tailnet directory headscale-init writes.
	TailnetReconcileMarker string `help:"File recording the pubkeys/ set last reconciled with headscale; losing it only costs one device re-enrollment" type:"path"`
}

// Validate implements kong.Validatable to enforce constraints beyond struct tags.
func (c *CLI) Validate() error {
	if c.Hostname == "" {
		return fmt.Errorf("hostname must not be empty")
	}
	if err := c.tsnetConfig().Validate(); err != nil {
		return err
	}
	if c.tsnetConfig().Enabled() && strings.TrimSpace(c.TailnetDomain) == "" {
		return fmt.Errorf("--tailnet-domain is required when --tsnet-dir is set, " +
			"otherwise clients are handed a hostname they cannot resolve")
	}
	if c.tailnetControlRelayEnabled() && strings.TrimSpace(c.TailnetControlUpstream) == "" {
		return fmt.Errorf("--tailnet-control-upstream is required when " +
			"--tailnet-control-addr is set, otherwise the listener accepts " +
			"control connections and has nowhere to send them")
	}
	if err := c.validateDiscovery(); err != nil {
		return err
	}
	if c.tsnetConfig().Enabled() && !c.pairingEnabled() {
		return fmt.Errorf("--tsnet-dir needs --headscale-api-url and the other " +
			"headscale flags, since gitd mints its own tailnet key over that API")
	}
	return nil
}

// Whether to serve the control plane on the tailnet as well as through the
// hosted relay. Requires tsnet, because without a node there is no tailnet to
// bind the listener to.
func (c *CLI) tailnetControlRelayEnabled() bool {
	return c.tsnetConfig().Enabled() && strings.TrimSpace(c.TailnetControlAddr) != ""
}

// Tailnet pairing needs every part of its headscale configuration or none of
// it. A partial configuration would start cleanly and then fail at the moment a
// user tries to pair a device, which is the worst time to find out.
//
// --discovery-url is deliberately not part of the group. Its presence is what
// distinguishes the two delivery modes: with it, records are published to the
// hosted discovery API; without it, gitd hands the record back for the
// authorizing device to display as a QR.
func (c *CLI) validateDiscovery() error {
	required := map[string]string{
		"--headscale-api-url":        strings.TrimSpace(c.HeadscaleAPIURL),
		"--headscale-api-key-file":   strings.TrimSpace(c.HeadscaleAPIKeyFile),
		"--headscale-client-url":     strings.TrimSpace(c.HeadscaleClientURL),
		"--tailnet-reconcile-marker": strings.TrimSpace(c.TailnetReconcileMarker),
	}

	missing := make([]string, 0, len(required))
	for flag, value := range required {
		if value == "" {
			missing = append(missing, flag)
		}
	}

	// No tailnet at all: LAN-only deployments and the integration harness.
	// Valid, but /pair is not offered.
	if len(missing) == len(required) {
		if strings.TrimSpace(c.DiscoveryURL) != "" {
			return fmt.Errorf("--discovery-url needs the headscale flags as well, " +
				"since a pairing record describes a tailnet gitd is not configured for")
		}
		return nil
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("tailnet pairing needs %s as well; "+
			"leave all of them unset to run without a tailnet",
			strings.Join(missing, ", "))
	}
	return nil
}

// Reports whether this deployment can produce pairing records at all.
func (c *CLI) pairingEnabled() bool {
	return strings.TrimSpace(c.HeadscaleAPIURL) != ""
}

// Assembles the discovery writer, or returns nil for manual-exposure mode.
//
// Returning a nil interface is what makes gitd's /pair endpoint answer 404 on
// manual deployments, so the two modes are decided in exactly one place.
func (c *CLI) headscaleClient() (*tailnet.Client, error) {
	if !c.pairingEnabled() {
		return nil, nil
	}

	return tailnet.NewClient(tailnet.Config{
		BaseURL:    c.HeadscaleAPIURL,
		APIKeyFile: c.HeadscaleAPIKeyFile,
		UserName:   c.HeadscaleUser,
	})
}

func (c *CLI) buildPairingPublisher(headscale *tailnet.Client) (gitd.PairingPublisher, error) {
	if headscale == nil {
		log.Printf("Tailnet pairing is disabled; gitd is serving on a host port without a tailnet")
		return nil, nil
	}

	// DiscoveryURL may be empty. That selects manual-exposure delivery, where
	// the record is returned to the authorizing device instead of published.
	publisher, err := pairing.NewPublisher(pairing.Config{
		CACertPath:   c.CA,
		HeadscaleURL: c.HeadscaleClientURL,
		DiscoveryURL: c.DiscoveryURL,
	})
	if err != nil {
		return nil, err
	}
	return publisher, nil
}

// Builds the reconciler that deletes device nodes when a key leaves pubkeys/,
// or nil on deployments without headscale, where there is nothing to revoke.
func (c *CLI) buildReconciler(headscale *tailnet.Client) (*tailnet.Reconciler, error) {
	if headscale == nil {
		return nil, nil
	}
	return tailnet.NewReconciler(tailnet.ReconcilerConfig{
		Nodes:          headscale,
		AuthorizedKeys: func() ([]string, error) { return authorizedKeyFingerprints(c.Repo) },
		MarkerPath:     c.TailnetReconcileMarker,
	})
}

// Reads pubkeys/ on main the same way authentication does and reduces it to
// fingerprints, so revocation and Git access always agree on who is a member.
func authorizedKeyFingerprints(repoPath string) ([]string, error) {
	keys, err := auth.ReadAuthorizedKeys(repoPath)
	if err != nil {
		return nil, err
	}
	fingerprints := make([]string, 0, len(keys))
	for _, key := range keys {
		fingerprints = append(fingerprints, auth.KeyFingerprint(key))
	}
	return fingerprints, nil
}

// Collects the tailnet flags into the shape tsnetserve expects. The minter is
// added in main, once the headscale client exists.
func (c *CLI) tsnetConfig() tsnetserve.Config {
	return tsnetserve.Config{
		Dir:        c.TsnetDir,
		ControlURL: c.TsnetControlURL,
		Hostname:   c.TsnetHostname,
	}
}

// Builds the Git URL shown in the LAN-only CA page.
//
// On a tailnet the CA page mints a join credential instead of a URL; clients
// already use pkg/tailnetaddr. This remains for integration tests and
// host-port gitd.
func (c *CLI) advertisedURL() string {
	if c.tsnetConfig().Enabled() {
		return tailnetaddr.GitdURL() + "/"
	}
	return advertisedServerURL(c.Hostname, c.Addr)
}

// The MagicDNS name tailnet peers use to reach this gitd.
func (c *CLI) tailnetHostname() string {
	return fmt.Sprintf("%s.%s",
		strings.TrimSpace(c.TsnetHostname),
		strings.Trim(strings.TrimSpace(c.TailnetDomain), "."))
}

// Builds the Git URL shown in QR and /config.json so onboarding clients
// connect to the same host and port gitd is listening on.
func advertisedServerURL(hostname, addr string) string {
	return fmt.Sprintf("https://%s%s/", hostname, addr)
}

// Wires CA distribution, mTLS gitd, and the internal read-only LFS listener so
// clients bootstrap and route Git/LFS through one endpoint while media services
// can fetch objects without mTLS.
func main() {
	var cli CLI
	ctx := kong.Parse(&cli,
		kong.Name("gitd"),
		kong.Description("Git HTTP server with mTLS authentication using P-256 ECDSA keys"),
		kong.UsageOnError(),
	)

	// Print the loaded CLI configuration
	log.Printf("Loaded CLI configuration: %+v", cli)

	// Read CA certificate for QR code distribution
	caData, err := os.ReadFile(cli.CA)
	ctx.FatalIfErrorf(err)

	serverURL := cli.advertisedURL()

	headscale, err := cli.headscaleClient()
	ctx.FatalIfErrorf(err)

	// Built before the CA page so the page and the Git server agree on when
	// the repository leaves bootstrap mode.
	auth := auth.NewAuthenticator(cli.Repo, cli.CacheTTL)

	caCfg := caserver.Config{CA: string(caData), ServerURL: serverURL}
	if headscale != nil {
		// A preauth key is single-use, so the CA page mints on each visit
		// rather than baking one credential into a QR at startup. This is
		// the only key a device gets without presenting a certificate in
		// pubkeys/. The page is published on the LAN by default, so it
		// mints only until the first push.
		caCfg.Bootstrapped = auth.HasBranch
		caCfg.Mint = func() (string, string, error) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			key, err := headscale.MintPreauthKey(ctx, tailnet.DeviceTag, tailnet.PreauthKeyTTL)
			if err != nil {
				return "", "", err
			}
			return cli.HeadscaleClientURL, key, nil
		}
	}

	// Start CA distribution HTTP server
	caHandler, err := caserver.NewHandler(caCfg)
	ctx.FatalIfErrorf(err)
	httpServer := &http.Server{
		Addr:    cli.CaAddr,
		Handler: caHandler,
	}

	go func() {
		log.Printf("Starting CA server on %s", cli.CaAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("CA server failed: %v", err)
		}
	}()

	pairingPublisher, err := cli.buildPairingPublisher(headscale)
	ctx.FatalIfErrorf(err)

	reconciler, err := cli.buildReconciler(headscale)
	ctx.FatalIfErrorf(err)
	var onPush func()
	if reconciler != nil {
		onPush = reconciler.Trigger
	}

	handler, err := gitd.NewServer(auth, gitd.ServerConfig{
		RepoPath:         cli.Repo,
		LfsDir:           cli.LfsDir,
		DecryptdURL:      cli.DecryptdURL,
		TranscodedURL:    cli.TranscodedURL,
		PairingPublisher: pairingPublisher,
		OnPush:           onPush,
	})
	ctx.FatalIfErrorf(err)

	// Reconciled once at startup as well as after each push, because a push
	// may have landed just before gitd last stopped.
	reconcileCtx, stopReconciling := context.WithCancel(context.Background())
	defer stopReconciling()
	if reconciler != nil {
		reconciler.Trigger()
		go reconciler.Run(reconcileCtx)
	}

	// Start HTTPS server with mTLS enabled
	gitServer := &http.Server{
		Addr:    cli.Addr,
		Handler: handler,
		TLSConfig: &tls.Config{
			ClientAuth: tls.RequireAnyClientCert,
			MinVersion: tls.VersionTLS13,
		},
	}

	// On a tailnet the Git listener is bound to the tsnet node, which is what
	// lets the compose stack publish no host ports at all. Without tsnet the
	// listener stays on the host, preserving LAN-only deployments. The two
	// cases are kept mutually exclusive so the host port is never bound even
	// momentarily in tailnet mode.
	var (
		tsnetNode   *tsnetserve.Node
		gitListener net.Listener
	)
	if cli.tsnetConfig().Enabled() {
		tsnetCfg := cli.tsnetConfig()
		// gitd's own node is tagged as the server, which is what keeps the
		// revocation sweep, which only drops device nodes, from touching it.
		tsnetCfg.Mint = func(ctx context.Context) (string, error) {
			return headscale.MintPreauthKey(ctx, tailnet.ServerTag, tailnet.PreauthKeyTTL)
		}
		joinCtx, cancelJoin := context.WithTimeout(context.Background(), tsnetJoinTimeout)
		tsnetNode, err = tsnetserve.Start(joinCtx, tsnetCfg)
		cancelJoin()
		ctx.FatalIfErrorf(err)
		log.Printf("Joined tailnet as %q with addresses %v", cli.TsnetHostname, tsnetNode.Addrs())
		gitListener, err = tsnetNode.Listen("tcp", cli.Addr)
	} else {
		gitListener, err = net.Listen("tcp", cli.Addr)
	}
	ctx.FatalIfErrorf(err)

	go func() {
		log.Printf("Starting gitd server on %s (tailnet=%t) for repository %s",
			cli.Addr, cli.tsnetConfig().Enabled(), cli.Repo)
		if err := gitServer.ServeTLS(gitListener, cli.Cert, cli.Key); err != nil && err != http.ErrServerClosed {
			log.Fatalf("gitd server failed: %v", err)
		}
	}()

	// The in-tailnet path to the control plane. A device that is already a
	// member reaches hsproxy through here instead of through the hosted relay,
	// which is what keeps the relay a bootstrap dependency rather than a
	// permanent one. Failing to bind is not fatal: devices can still reach the
	// control plane the way they did during pairing.
	if cli.tailnetControlRelayEnabled() {
		controlListener, err := tsnetNode.Listen("tcp", cli.TailnetControlAddr)
		if err != nil {
			log.Printf("Tailnet control path unavailable on %s; devices will keep "+
				"using the relay: %v", cli.TailnetControlAddr, err)
		} else {
			go func() {
				log.Printf("Relaying tailnet control traffic from %s to %s",
					cli.TailnetControlAddr, cli.TailnetControlUpstream)
				err := tcprelay.Serve(controlListener, tcprelay.Config{
					UpstreamAddr: cli.TailnetControlUpstream,
				})
				if err != nil && !errors.Is(err, net.ErrClosed) {
					log.Printf("tailnet control relay stopped: %v", err)
				}
			}()
		}
	}

	var lfsInternalServer *http.Server
	if cli.LfsInternalAddr != "" {
		lfsInternalServer = &http.Server{
			Addr:    cli.LfsInternalAddr,
			Handler: lfs.NewReadOnlyHandler(handler.LFSHandler().Store(), "/lfs"),
		}
		go func() {
			log.Printf("Starting internal read-only LFS server on %s", cli.LfsInternalAddr)
			if err := lfsInternalServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Fatalf("internal LFS server failed: %v", err)
			}
		}()
	}

	// Set up signal handling for graceful shutdown
	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Wait for shutdown signal
	<-signalCtx.Done()
	log.Println("Received signal, initiating graceful shutdown...")

	// Create shutdown context with 30-second timeout
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Shutdown servers concurrently
	var wg sync.WaitGroup
	servers := []*http.Server{httpServer, gitServer}
	if lfsInternalServer != nil {
		servers = append(servers, lfsInternalServer)
	}
	wg.Add(len(servers))

	for _, srv := range servers {
		go func(srv *http.Server) {
			defer wg.Done()
			log.Printf("Shutting down server on %s...", srv.Addr)
			if err := srv.Shutdown(shutdownCtx); err != nil {
				log.Printf("server %s shutdown error: %v", srv.Addr, err)
			} else {
				log.Printf("server %s shutdown complete", srv.Addr)
			}
		}(srv)
	}

	wg.Wait()

	// Closed after the HTTP servers so in-flight Git operations finish before
	// the tailnet interface disappears from under them.
	if tsnetNode != nil {
		if err := tsnetNode.Close(); err != nil {
			log.Printf("tailnet node shutdown error: %v", err)
		} else {
			log.Println("tailnet node shutdown complete")
		}
	}

	log.Println("Shutdown complete")
}
