package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/decryptproxy"
)

// CLI captures runtime options for running decryptd in local and container environments.
type CLI struct {
	Listen   string `kong:"default=':8084',help='Server listen address'"`
	Upstream string `kong:"default='http://admin:admin@lfs:8083',help='Upstream LFS base URL'"`
}

// main starts the decrypting proxy and handles graceful shutdown for request safety.
func main() {
	var cli CLI
	kong.Parse(&cli)

	server, err := decryptproxy.NewServer(decryptproxy.ServerConfig{
		ListenAddr:  cli.Listen,
		UpstreamURL: cli.Upstream,
	})
	if err != nil {
		log.Fatalf("failed to initialize decrypt proxy: %v", err)
	}

	httpServer := &http.Server{
		Addr:    cli.Listen,
		Handler: server.Handler(),
	}

	go func() {
		log.Printf("decryptd starting on %s", cli.Listen)
		log.Printf("decryptd upstream configured")
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("decryptd failed: %v", err)
		}
	}()

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-signalCtx.Done()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("decryptd shutdown failed: %v", err)
	}
}
