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

// Bounds minting gitd's own tailnet key at startup. tailnetnode bounds the
// join itself; a headscale that never answers should restart gitd rather
// than hang it, and compose does the restarting.
const mintTimeout = 30 * time.Second

// CLI for gitd - Git HTTP server with mTLS authentication.
// Provides secure, certificate-based access to Git repositories.
//
// gitd serves Git only on the tailnet, so the tailnet and headscale flags are
// required. Its name, domain and ports there are build constants in
// pkg/tailnetaddr, because clients, certificates and the headscale policy all
// depend on them.
type CLI struct {
	Repo     string        `required:"" help:"Path to Git repository (must be a bare repository)" type:"path"`
	CaAddr   string        `default:":8080" help:"CA distribution listen address"`
	Cert     string        `required:"" help:"Path to server TLS certificate" type:"path"`
	Key      string        `required:"" help:"Path to server TLS private key" type:"path"`
	CA       string        `required:"" help:"Path to CA certificate for client trust" type:"path"`
	CacheTTL time.Duration `default:"5m" help:"Cache TTL for authorized keys"`
	Check    bool          `help:"Run health check and exit"`
	LfsDir   string        `required:"" help:"Directory for the native file-backed LFS object store" type:"path"`

	// LfsInternalAddr is the plain-HTTP listener for compose-network readers
	// such as decryptd. Empty disables it so tests can omit the listener.
	LfsInternalAddr string `default:":8085" help:"Internal read-only LFS listen address (empty disables)"`

	DecryptdURL   string `required:"" help:"Internal decryptd URL proxied at /decryptd (full URL, e.g., http://decryptd:8084)"`
	TranscodedURL string `required:"" help:"Internal transcoded URL proxied at /transcoded (full URL, e.g., http://transcoded:8082)"`

	TsnetDir        string `required:"" help:"Directory for tailnet node state" type:"path"`
	TsnetControlURL string `required:"" help:"Headscale control URL for the tailnet node (e.g. http://headscale:8080)"`

	// A second way into the control plane, reachable only from inside the
	// tailnet. Devices bootstrap through the hosted relay because they have no
	// tailnet yet, but once they are members they should not keep depending on
	// a hosted service to stay connected. Splicing to hsproxy rather than to
	// headscale keeps the device's TLS session terminating at the same
	// authenticating front door on both paths.
	TailnetControlUpstream string `default:"hsproxy:8443" help:"hsproxy address that tailnet control-plane traffic is spliced to"`

	// Cloud discovery. Without a discovery URL gitd runs in manual-exposure
	// mode, where the authorizing device shows the sealed record as a QR and
	// no record is ever published.
	DiscoveryURL        string `help:"Base URL of the discovery API; the pairing slot is prepended as a subdomain. Leave unset for manual-exposure mode"`
	HeadscaleAPIURL     string `name:"headscale-api-url" required:"" help:"Headscale API base URL used to mint keys for gitd and the first device, and to expire revoked device nodes (e.g. http://headscale:8080)"`
	HeadscaleAPIKeyFile string `required:"" help:"File containing the headscale API key; read from a file so it stays out of logs and the process list" type:"path"`
	HeadscaleUser       string `default:"replycant" help:"Headscale user that paired devices are registered under"`

	// The URL a pairing device should use to reach headscale. Distinct from
	// --headscale-api-url, which is the compose-internal address gitd itself
	// uses: devices reach the control plane through the tunnel or a forwarded
	// port, never over the compose network.
	HeadscaleClientURL string `required:"" help:"Headscale URL advertised to pairing devices (the tunnel hostname, or your own DNS name in manual mode)"`

	// Records which keys were authorized the last time headscale was
	// reconciled with pubkeys/, so a removal can be told apart from a
	// restart, and which key each device node authenticates with, so a
	// revocation only expires the nodes it has to. Lives in gitd's own
	// writable state, not in the read-only tailnet directory headscale-init
	// writes.
	TailnetReconcileMarker string `required:"" help:"File recording the pubkeys/ set last reconciled with headscale and the key each device node uses; losing it only costs one device re-enrollment" type:"path"`
}

// Validate implements kong.Validatable to enforce constraints beyond struct tags.
func (c *CLI) Validate() error {
	return c.tsnetConfig().Validate()
}

func (c *CLI) headscaleClient() (*tailnet.Client, error) {
	return tailnet.NewClient(tailnet.Config{
		BaseURL:    c.HeadscaleAPIURL,
		APIKeyFile: c.HeadscaleAPIKeyFile,
		UserName:   c.HeadscaleUser,
	})
}

// Builds the publisher that seals pairing records. DiscoveryURL may be empty,
// which selects manual-exposure delivery: the record is returned to the
// authorizing device instead of published.
func (c *CLI) buildPairingPublisher() (gitd.PairingPublisher, error) {
	return pairing.NewPublisher(pairing.Config{
		CACertPath:   c.CA,
		HeadscaleURL: c.HeadscaleClientURL,
		DiscoveryURL: c.DiscoveryURL,
	})
}

// Builds the reconciler that expires device nodes when a key leaves pubkeys/.
func (c *CLI) buildReconciler(headscale *tailnet.Client) (*tailnet.Reconciler, error) {
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
		Hostname:   tailnetaddr.GitdHostname,
	}
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

	headscale, err := cli.headscaleClient()
	ctx.FatalIfErrorf(err)

	// Built before the CA page so the page and the Git server agree on when
	// the repository leaves bootstrap mode.
	auth := auth.NewAuthenticator(cli.Repo, cli.CacheTTL)

	// A preauth key is single-use, so the CA page mints on each visit rather
	// than baking one credential into a QR at startup. This is the only key a
	// device gets without presenting a certificate in pubkeys/. The page is
	// published on the LAN by default, so it mints only until the first push.
	caHandler, err := caserver.NewHandler(caserver.Config{
		CA:           string(caData),
		Bootstrapped: auth.HasBranch,
		Mint: func() (string, string, error) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			key, err := headscale.MintPreauthKey(ctx, tailnet.DeviceTag, tailnet.PreauthKeyTTL)
			if err != nil {
				return "", "", err
			}
			return cli.HeadscaleClientURL, key, nil
		},
	})
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

	pairingPublisher, err := cli.buildPairingPublisher()
	ctx.FatalIfErrorf(err)

	reconciler, err := cli.buildReconciler(headscale)
	ctx.FatalIfErrorf(err)

	// The Git listener is bound to the tsnet node, which is what lets the
	// compose stack publish no host port for Git at all.
	tsnetCfg := cli.tsnetConfig()
	// gitd's own node is tagged as the server, which is what keeps the
	// revocation sweep, which only drops device nodes, from touching it.
	tsnetCfg.Mint = func(ctx context.Context) (string, error) {
		return headscale.MintPreauthKey(ctx, tailnet.ServerTag, tailnet.PreauthKeyTTL)
	}
	mintCtx, cancelMint := context.WithTimeout(context.Background(), mintTimeout)
	tsnetNode, err := tsnetserve.Start(mintCtx, tsnetCfg)
	cancelMint()
	ctx.FatalIfErrorf(err)
	log.Printf("Joined tailnet as %q with addresses %v", tailnetaddr.GitdHost, tsnetNode.Addrs())
	gitListener, err := tsnetNode.Listen("tcp", fmt.Sprintf(":%d", tailnetaddr.GitdPort))
	ctx.FatalIfErrorf(err)

	handler, err := gitd.NewServer(auth, gitd.ServerConfig{
		RepoPath:         cli.Repo,
		LfsDir:           cli.LfsDir,
		DecryptdURL:      cli.DecryptdURL,
		TranscodedURL:    cli.TranscodedURL,
		PairingPublisher: pairingPublisher,
		OnPush:           reconciler.Trigger,
		NodeBinder:       tailnet.NewNodeBinder(tsnetNode.WhoIs, reconciler.Bind, log.Printf),
	})
	ctx.FatalIfErrorf(err)

	// Reconciled once at startup as well as after each push, because a push
	// may have landed just before gitd last stopped.
	reconcileCtx, stopReconciling := context.WithCancel(context.Background())
	defer stopReconciling()
	reconciler.Trigger()
	go reconciler.Run(reconcileCtx)

	// Start HTTPS server with mTLS enabled
	gitServer := &http.Server{
		Addr:    tailnetaddr.GitdURL(),
		Handler: handler,
		TLSConfig: &tls.Config{
			ClientAuth: tls.RequireAnyClientCert,
			MinVersion: tls.VersionTLS13,
		},
	}

	go func() {
		log.Printf("Starting gitd server on %s for repository %s", tailnetaddr.GitdURL(), cli.Repo)
		if err := gitServer.ServeTLS(gitListener, cli.Cert, cli.Key); err != nil && err != http.ErrServerClosed {
			log.Fatalf("gitd server failed: %v", err)
		}
	}()

	// The in-tailnet path to the control plane. A device that is already a
	// member reaches hsproxy through here instead of through the hosted relay,
	// which is what keeps the relay a bootstrap dependency rather than a
	// permanent one. Failing to bind is not fatal: devices can still reach the
	// control plane the way they did during pairing.
	controlListener, err := tsnetNode.Listen("tcp", fmt.Sprintf(":%d", tailnetaddr.ControlPort))
	if err != nil {
		log.Printf("Tailnet control path unavailable on %s; devices will keep "+
			"using the relay: %v", tailnetaddr.ControlAddr(), err)
	} else {
		go func() {
			log.Printf("Relaying tailnet control traffic from %s to %s",
				tailnetaddr.ControlAddr(), cli.TailnetControlUpstream)
			err := tcprelay.Serve(controlListener, tcprelay.Config{
				UpstreamAddr: cli.TailnetControlUpstream,
			})
			if err != nil && !errors.Is(err, net.ErrClosed) {
				log.Printf("tailnet control relay stopped: %v", err)
			}
		}()
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
	if err := tsnetNode.Close(); err != nil {
		log.Printf("tailnet node shutdown error: %v", err)
	} else {
		log.Println("tailnet node shutdown complete")
	}

	log.Println("Shutdown complete")
}
