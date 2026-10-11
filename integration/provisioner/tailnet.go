package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetshim"
	"tailscale.com/tsnet"
)

// qrPayload is the JSON the clone's loopback page serves for scripted
// approval. It is the same object the QR code encodes.
type qrPayload struct {
	PairingSecret string `json:"pairing_secret"`
	AgePublicKey  string `json:"age_pubkey"`
}

// approveTailnetPairing is what an already-enrolled device does after it
// has committed the new key: join the tailnet and ask gitd to publish the
// discovery record. gitd's /pair handler is only reachable inside the
// tailnet, and only by a certificate already in pubkeys/.
func approveTailnetPairing(ctx context.Context, identityDir, caPEM, headscaleURL, pairURL string, payload qrPayload) error {
	client, cleanup, err := tailnetHTTPClient(ctx, identityDir, caPEM, headscaleURL)
	if err != nil {
		return err
	}
	defer cleanup()
	return postPairingRecord(ctx, client, pairURL, payload.PairingSecret)
}

func fetchQRPayload(ctx context.Context, qrURL string) (qrPayload, error) {
	deadline := time.Now().Add(30 * time.Second)
	var last error
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, qrURL, nil)
		if err != nil {
			return qrPayload{}, err
		}
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			last = err
		} else {
			body, readErr := io.ReadAll(io.LimitReader(response.Body, 1<<20))
			response.Body.Close()
			if response.StatusCode == http.StatusOK && readErr == nil {
				var payload qrPayload
				if err := json.Unmarshal(body, &payload); err != nil {
					return qrPayload{}, fmt.Errorf("decode pairing QR payload: %w", err)
				}
				if strings.TrimSpace(payload.PairingSecret) == "" || strings.TrimSpace(payload.AgePublicKey) == "" {
					return qrPayload{}, fmt.Errorf("pairing QR payload is missing pairing_secret or age_pubkey")
				}
				return payload, nil
			}
			last = fmt.Errorf("QR payload returned %s", response.Status)
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			if ctx.Err() != nil {
				return qrPayload{}, ctx.Err()
			}
			return qrPayload{}, fmt.Errorf("pairing QR payload was not available: %w", last)
		}
		select {
		case <-ctx.Done():
			return qrPayload{}, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func postPairingRecord(ctx context.Context, client *http.Client, pairURL, secret string) error {
	body, err := json.Marshal(map[string]string{
		"pairing_secret": secret,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, pairURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("post pairing record: %w", err)
	}
	defer response.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
	if response.StatusCode != http.StatusNoContent {
		return fmt.Errorf("gitd /pair returned %s: %s", response.Status, strings.TrimSpace(string(respBody)))
	}
	return nil
}

// tailnetHTTPClient joins as the seeder and returns a client whose dials
// stay inside that node. The caller closes the node when the POST returns;
// the seeder does not need to remain on the tailnet.
//
// The seeder is already in pubkeys/, so it mints its own key through hsproxy
// like any paired device. The CA page cannot serve it: that page only hands
// out keys while the repository is still empty.
func tailnetHTTPClient(ctx context.Context, identityDir, caPEM, headscaleURL string) (*http.Client, func(), error) {
	cert, err := tls.LoadX509KeyPair(
		filepath.Join(identityDir, "client-cert.pem"),
		filepath.Join(identityDir, "client-key.pem"),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("load seeder client certificate: %w", err)
	}
	addr, serverName, err := headscaleAddr(headscaleURL)
	if err != nil {
		return nil, nil, err
	}
	shim, err := tailnetshim.New(tailnetshim.Config{
		UpstreamAddr:       addr,
		UpstreamServerName: serverName,
		CAPEM:              []byte(caPEM),
		ClientCertificate:  cert,
		Logf:               log.Printf,
	})
	if err != nil {
		return nil, nil, err
	}
	if err := shim.Start(); err != nil {
		return nil, nil, err
	}
	shimCtx, cancelShim := context.WithCancel(ctx)
	go shim.Serve(shimCtx)

	preauthKey, err := shim.MintPreauthKey(ctx)
	if err != nil {
		cancelShim()
		shim.Close()
		return nil, nil, fmt.Errorf("seeder could not mint a tailnet key: %w", err)
	}

	host, err := randomHostname()
	if err != nil {
		cancelShim()
		shim.Close()
		return nil, nil, err
	}
	stateDir, err := os.MkdirTemp("", "provisioner-tsnet-")
	if err != nil {
		cancelShim()
		shim.Close()
		return nil, nil, err
	}
	node := &tsnet.Server{
		Dir:        stateDir,
		Hostname:   host,
		ControlURL: shim.ControlURL(),
		AuthKey:    preauthKey,
		UserLogf:   log.Printf,
		Logf:       func(string, ...any) {},
	}
	joinCtx, cancelJoin := context.WithTimeout(ctx, 2*time.Minute)
	_, err = node.Up(joinCtx)
	cancelJoin()
	if err != nil {
		cancelShim()
		shim.Close()
		_ = node.Close()
		_ = os.RemoveAll(stateDir)
		return nil, nil, fmt.Errorf("seeder failed to join the tailnet: %w", err)
	}

	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(caPEM)) {
		cancelShim()
		shim.Close()
		_ = node.Close()
		_ = os.RemoveAll(stateDir)
		return nil, nil, fmt.Errorf("seeder CA is not a PEM certificate")
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return node.Dial(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{
			MinVersion:   tls.VersionTLS13,
			RootCAs:      pool,
			Certificates: []tls.Certificate{cert},
			ServerName:   "gitd.replycant.internal",
		},
	}
	cleanup := func() {
		cancelShim()
		shim.Close()
		_ = node.Close()
		_ = os.RemoveAll(stateDir)
	}
	return &http.Client{Transport: transport, Timeout: 30 * time.Second}, cleanup, nil
}

func headscaleAddr(raw string) (string, string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", "", fmt.Errorf("headscale URL is not a valid URL: %w", err)
	}
	host := parsed.Hostname()
	if host == "" {
		return "", "", fmt.Errorf("headscale URL has no hostname: %q", raw)
	}
	port := parsed.Port()
	if port == "" {
		if parsed.Scheme == "http" {
			port = "80"
		} else {
			port = "443"
		}
	}
	return net.JoinHostPort(host, port), host, nil
}

func randomHostname() (string, error) {
	buf := make([]byte, 4)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "seeder-" + hex.EncodeToString(buf), nil
}
