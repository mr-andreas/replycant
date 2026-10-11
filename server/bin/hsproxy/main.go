// Command hsproxy is the authenticating front door for headscale.
//
// It exists because headscale cannot verify client certificates itself, and
// its listener is the one endpoint this deployment publishes to the internet
// through the reverse TCP tunnel. Without this hop, anyone who discovered the
// tunnel hostname could register nodes on the tailnet.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/mr-andreas/replycant/server/hsproxy"
	"github.com/mr-andreas/replycant/server/tailnet"
)

// Mirrors gitd's flag shape so operators configure both services the same way,
// including sharing the same repository as the source of authorized devices.
type CLI struct {
	Repo     string        `required:"" help:"Path to the bare Git repository holding pubkeys/ (source of authorized devices)" type:"path"`
	Addr     string        `default:":8443" help:"mTLS listen address for headscale control traffic"`
	Upstream string        `required:"" help:"Headscale plain-HTTP address to relay to (e.g. headscale:8080)"`
	Cert     string        `required:"" help:"Path to the server TLS certificate issued by the replycant CA" type:"path"`
	Key      string        `required:"" help:"Path to the server TLS private key" type:"path"`
	// Sent after the leaf in every handshake. A phone restoring from a
	// recovery key holds only the CA's hash and can reach nothing but
	// hsproxy, so this is where it obtains the CA it checks against it.
	CA       string        `required:"" help:"Path to the replycant CA certificate, sent in the TLS chain" type:"path"`
	CacheTTL time.Duration `default:"5m" help:"Cache TTL for authorized keys"`

	// Separate from Addr because readiness probes have no device identity to
	// present and must never be reachable through the tunnel.
	HealthAddr string `default:":8091" help:"Plain-HTTP readiness listen address (empty disables)"`

	// Lets hsproxy mint a fresh pre-auth key for any device in pubkeys/, which
	// is what makes headscale's database a cache: a device it forgot simply
	// asks again. The API key is read from a file so it never appears in
	// flags or the process listing.
	HeadscaleAPIURL     string `name:"headscale-api-url" help:"Headscale API base URL for minting device keys (e.g. http://headscale:8080)"`
	HeadscaleAPIKeyFile string `help:"Path to the headscale API key used to mint device keys" type:"path"`
	HeadscaleUser       string `default:"replycant" help:"Headscale user devices belong to"`
}

// Validate implements kong.Validatable to catch address mistakes at startup,
// where they are obvious, instead of on a device connection, where they look
// like a client bug.
func (c *CLI) Validate() error {
	if strings.TrimSpace(c.Upstream) == "" {
		return fmt.Errorf("upstream must not be empty")
	}
	if strings.Contains(c.Upstream, "://") {
		return fmt.Errorf("upstream must be a host:port address, not a URL: %q", c.Upstream)
	}
	if (c.HeadscaleAPIURL == "") != (c.HeadscaleAPIKeyFile == "") {
		return fmt.Errorf("--headscale-api-url and --headscale-api-key-file must be set together")
	}
	return nil
}

// Builds the key minter, or nil when the deployment does not issue keys
// through hsproxy. The key file is re-read per call, because headscale-init
// replaces it after headscale's database is wiped while hsproxy keeps running.
func (c *CLI) minter() (hsproxy.Minter, error) {
	if c.HeadscaleAPIURL == "" {
		return nil, nil
	}
	return tailnet.NewClient(tailnet.Config{
		BaseURL:    c.HeadscaleAPIURL,
		APIKeyFile: c.HeadscaleAPIKeyFile,
		UserName:   c.HeadscaleUser,
	})
}

// Loads hsproxy's certificate with the CA appended to its chain.
//
// Fails when the CA did not sign the leaf: a recovering phone would accept the
// CA by its hash and then be unable to verify hsproxy, which looks like a
// network fault rather than a misconfigured deployment.
func loadServerCertificate(certPath, keyPath, caPath string) (tls.Certificate, error) {
	serverCert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return tls.Certificate{}, err
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("read the CA certificate: %w", err)
	}
	block, _ := pem.Decode(caPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return tls.Certificate{}, fmt.Errorf("%s holds no PEM certificate", caPath)
	}
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("parse the CA certificate: %w", err)
	}
	leaf, err := x509.ParseCertificate(serverCert.Certificate[0])
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("parse the server certificate: %w", err)
	}
	if err := leaf.CheckSignatureFrom(ca); err != nil {
		return tls.Certificate{}, fmt.Errorf("the server certificate was not issued by %s: %w", caPath, err)
	}
	serverCert.Certificate = append(serverCert.Certificate[:1], ca.Raw)
	return serverCert, nil
}

func main() {
	var cli CLI
	ctx := kong.Parse(&cli,
		kong.Name("hsproxy"),
		kong.Description("mTLS front door for headscale, authorizing devices against pubkeys/ in the git repository"),
		kong.UsageOnError(),
	)

	log.Printf("Loaded CLI configuration: %+v", cli)

	serverCert, err := loadServerCertificate(cli.Cert, cli.Key, cli.CA)
	ctx.FatalIfErrorf(err)

	minter, err := cli.minter()
	ctx.FatalIfErrorf(err)

	proxy, err := hsproxy.New(hsproxy.Config{
		Authorizer:   auth.NewAuthenticator(cli.Repo, cli.CacheTTL),
		UpstreamAddr: cli.Upstream,
		ServerCert:   serverCert,
		Minter:       minter,
	})
	ctx.FatalIfErrorf(err)

	listener, err := net.Listen("tcp", cli.Addr)
	ctx.FatalIfErrorf(err)

	go func() {
		log.Printf("Starting hsproxy on %s relaying to %s", cli.Addr, cli.Upstream)
		if err := proxy.Serve(listener); err != nil {
			log.Printf("hsproxy listener stopped: %v", err)
		}
	}()

	var healthServer *http.Server
	if cli.HealthAddr != "" {
		healthServer = &http.Server{
			Addr:    cli.HealthAddr,
			Handler: proxy.HealthHandler(),
		}
		go func() {
			log.Printf("Starting hsproxy readiness server on %s", cli.HealthAddr)
			if err := healthServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("hsproxy readiness server failed: %v", err)
			}
		}()
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-signalCtx.Done()
	log.Println("Received signal, initiating graceful shutdown...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := listener.Close(); err != nil {
		log.Printf("hsproxy listener close error: %v", err)
	}
	if healthServer != nil {
		if err := healthServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("readiness server shutdown error: %v", err)
		}
	}
	log.Println("Shutdown complete")
}
