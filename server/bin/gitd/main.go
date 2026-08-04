package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/gitd"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/mr-andreas/replycant/server/gitd/caserver"
)

// CLI for gitd - Git HTTP server with mTLS authentication.
// Provides secure, certificate-based access to Git repositories.
type CLI struct {
	Repo     string        `required:"" help:"Path to Git repository (must be a bare repository)" type:"path"`
	Addr     string        `default:":8443" help:"Server address to listen on"`
	Cert     string        `required:"" help:"Path to server TLS certificate" type:"path"`
	Key      string        `required:"" help:"Path to server TLS private key" type:"path"`
	CA       string        `required:"" help:"Path to CA certificate for client trust" type:"path"`
	CacheTTL time.Duration `default:"5m" help:"Cache TTL for authorized keys"`
	Check    bool          `help:"Run health check and exit"`
	Hostname string        `required:"" help:"Hostname to use for the server. Not used for anything, except for presenting a URL in the QR code scanned by apps."`
	LfsURL   string        `required:"" help:"Internal LFS server URL proxied at /lfs (full URL, e.g., http://admin:admin@lfs:8083)"`

	DecryptdURL   string `required:"" help:"Internal decryptd URL proxied at /decryptd (full URL, e.g., http://decryptd:8084)"`
	TranscodedURL string `required:"" help:"Internal transcoded URL proxied at /transcoded (full URL, e.g., http://transcoded:8082)"`
}

// Validate implements kong.Validatable to enforce constraints beyond struct tags.
func (c *CLI) Validate() error {
	if c.Hostname == "" {
		return fmt.Errorf("hostname must not be empty")
	}
	return nil
}

// Wires CA distribution and mTLS gitd servers so clients bootstrap and route Git/LFS through one endpoint.
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

	// Build server URL for QR code
	serverURL := fmt.Sprintf("https://%s%s/", cli.Hostname, cli.Addr)

	// Start CA distribution HTTP server
	caHandler, err := caserver.NewHandler(string(caData), serverURL)
	ctx.FatalIfErrorf(err)
	httpServer := &http.Server{
		Addr:    ":8080",
		Handler: caHandler,
	}

	go func() {
		log.Printf("Starting CA server on :8080")
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("CA server failed: %v", err)
		}
	}()

	// Create mTLS Git server handler
	auth := auth.NewAuthenticator(cli.Repo, cli.CacheTTL)

	handler, err := gitd.NewServer(auth, gitd.ServerConfig{
		RepoPath:      cli.Repo,
		LfsURL:        cli.LfsURL,
		DecryptdURL:   cli.DecryptdURL,
		TranscodedURL: cli.TranscodedURL,
	})
	ctx.FatalIfErrorf(err)

	// Start HTTPS server with mTLS enabled
	gitServer := &http.Server{
		Addr:    cli.Addr,
		Handler: handler,
		TLSConfig: &tls.Config{
			ClientAuth: tls.RequireAnyClientCert,
			MinVersion: tls.VersionTLS13,
		},
	}

	go func() {
		log.Printf("Starting gitd server on %s for repository %s", cli.Addr, cli.Repo)
		if err := gitServer.ListenAndServeTLS(cli.Cert, cli.Key); err != nil && err != http.ErrServerClosed {
			log.Fatalf("gitd server failed: %v", err)
		}
	}()

	// Set up signal handling for graceful shutdown
	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Wait for shutdown signal
	<-signalCtx.Done()
	log.Println("Received signal, initiating graceful shutdown...")

	// Create shutdown context with 30-second timeout
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Shutdown both servers concurrently
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		log.Println("Shutting down CA server...")
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("CA server shutdown error: %v", err)
		} else {
			log.Println("CA server shutdown complete")
		}
	}()

	go func() {
		defer wg.Done()
		log.Println("Shutting down gitd server...")
		if err := gitServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("gitd server shutdown error: %v", err)
		} else {
			log.Println("gitd server shutdown complete")
		}
	}()

	wg.Wait()
	log.Println("Shutdown complete")
}
