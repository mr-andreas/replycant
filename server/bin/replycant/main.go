package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/google/uuid"
	"github.com/mr-andreas/replycant/server/keygen"
)

const (
	defaultValidity = 10 * 365 * 24 * time.Hour
)

// Defines replycant CLI commands so operators can bootstrap device identities from terminal workflows.
type CLI struct {
	Keygen KeygenCmd `cmd:"" help:"Generate a P-256 key pair and serve a QR page for iOS device linking"`
}

// Captures key generation inputs to produce mTLS credentials and a linkable QR payload.
type KeygenCmd struct {
	Name    string `required:"" help:"Device name to include in the generated public key payload"`
	KeyOut  string `default:"device.key" help:"Output path for private key PEM" type:"path"`
	CertOut string `default:"device.crt" help:"Output path for certificate PEM" type:"path"`
	Addr    string `default:":8090" help:"HTTP listen address for QR web page"`
}

// Starts CLI parsing and dispatch so subcommands run with consistent argument validation.
func main() {
	var cli CLI
	ctx := kong.Parse(
		&cli,
		kong.Name("replycant"),
		kong.Description("Utility commands for replycant repository/device operations"),
		kong.UsageOnError(),
	)

	err := ctx.Run()
	ctx.FatalIfErrorf(err)
}

// Runs key generation end-to-end so a device can be linked by scanning a QR code from another device.
func (k *KeygenCmd) Run() error {
	deviceUUID := uuid.NewString()

	privateKeyPEM, certPEM, publicKey, err := keygen.GenerateKeyAndCert(k.Name, defaultValidity)
	if err != nil {
		return err
	}

	if err := writeOutputFile(k.KeyOut, privateKeyPEM, 0o600); err != nil {
		return err
	}
	if err := writeOutputFile(k.CertOut, certPEM, 0o644); err != nil {
		return err
	}

	handler, err := keygen.NewHandler(k.Name, deviceUUID, publicKey)
	if err != nil {
		return err
	}

	server := &http.Server{
		Addr:    k.Addr,
		Handler: handler,
	}

	serverErr := make(chan error, 1)
	go func() {
		err := server.ListenAndServe()
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			serverErr <- nil
			return
		}
		serverErr <- err
	}()

	fmt.Printf("Device name: %s\n", k.Name)
	fmt.Printf("Device UUID: %s\n", deviceUUID)
	fmt.Printf("Private key: %s\n", k.KeyOut)
	fmt.Printf("Certificate: %s\n", k.CertOut)
	fmt.Printf("Public key:\n%s\n\n", publicKey)
	fmt.Printf("Open %s to scan the device QR code.\n", qrURLForAddr(k.Addr))
	fmt.Println("Press Ctrl+C to stop.")

	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	select {
	case <-signalCtx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("failed to shutdown keygen server: %w", err)
		}
		return nil
	case err := <-serverErr:
		if err != nil {
			return fmt.Errorf("keygen server failed: %w", err)
		}
		return nil
	}
}

// Writes generated credential files with secure permissions so keys are durable across sessions.
func writeOutputFile(path string, content []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	if err := os.WriteFile(path, content, perm); err != nil {
		return fmt.Errorf("failed to write %s: %w", path, err)
	}

	log.Printf("wrote %s", path)
	return nil
}

// Normalizes user-provided listen address into a browser-friendly URL for onboarding output.
func qrURLForAddr(addr string) string {
	if len(addr) > 0 && addr[0] == ':' {
		return "http://localhost" + addr
	}
	return "http://" + addr
}
