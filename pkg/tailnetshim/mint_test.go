package tailnetshim

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
)

// Stands in for hsproxy's key endpoint: requires a client certificate, records
// who asked and for what, and answers with a fixed status and key.
type fakeKeyEndpoint struct {
	listener net.Listener
	status   int
	key      string

	mu       sync.Mutex
	requests []string
	subjects []string
}

func newFakeKeyEndpoint(t *testing.T, pki *testPKI, serverName string, status int) *fakeKeyEndpoint {
	t.Helper()

	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	fake := &fakeKeyEndpoint{status: status, key: "hskey-auth-minted"}
	fake.listener = tls.NewListener(raw, &tls.Config{
		Certificates: []tls.Certificate{pki.issue(t, serverName, []string{serverName})},
		ClientAuth:   tls.RequireAnyClientCert,
		MinVersion:   tls.VersionTLS12,
	})

	server := &http.Server{
		ReadHeaderTimeout: 10 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			subject := ""
			if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
				subject = r.TLS.PeerCertificates[0].Subject.CommonName
			}
			fake.mu.Lock()
			fake.requests = append(fake.requests, r.Method+" "+r.URL.Path)
			fake.subjects = append(fake.subjects, subject)
			fake.mu.Unlock()

			if fake.status != http.StatusOK {
				w.WriteHeader(fake.status)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"preauth_key": fake.key})
		}),
	}
	go func() { _ = server.Serve(fake.listener) }()
	t.Cleanup(func() { _ = server.Close() })
	return fake
}

func (f *fakeKeyEndpoint) addr() string { return f.listener.Addr().String() }

func (f *fakeKeyEndpoint) snapshot() (requests, subjects []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.requests...), append([]string(nil), f.subjects...)
}

func newMintingShim(t *testing.T, pki *testPKI, upstreamAddr, serverName string) *Shim {
	t.Helper()
	shim, err := New(Config{
		UpstreamAddr:       upstreamAddr,
		UpstreamServerName: serverName,
		CAPEM:              pki.caPEM,
		ClientCertificate:  pki.clientCert,
	})
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	return shim
}

func mintContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// A device whose headscale node is gone has to get a fresh key on its own.
// hsproxy only hands one out to a certificate in pubkeys/, so the request must
// carry the device certificate, and it must hit the one path hsproxy answers
// itself instead of splicing to headscale.
func TestMintPreauthKeyPresentsTheDeviceCertificate(t *testing.T) {
	pki := newTestPKI(t)
	endpoint := newFakeKeyEndpoint(t, pki, "abc.tunnel.replycant.com", http.StatusOK)
	shim := newMintingShim(t, pki, endpoint.addr(), "abc.tunnel.replycant.com")

	key, err := shim.MintPreauthKey(mintContext(t))
	if err != nil {
		t.Fatalf("an authorized device must get a key: %v", err)
	}
	if key != "hskey-auth-minted" {
		t.Errorf("unexpected key %q", key)
	}

	requests, subjects := endpoint.snapshot()
	if len(requests) != 1 || requests[0] != "POST "+tailnetaddr.PreauthKeyPath {
		t.Errorf("expected one POST to %s, got %v", tailnetaddr.PreauthKeyPath, requests)
	}
	if len(subjects) != 1 || subjects[0] != "device" {
		t.Errorf("the request must present the device certificate, upstream saw %v", subjects)
	}
}

// The key is a tailnet credential. Sending the device certificate to, and
// accepting a key from, anything not signed by the deployment CA would let an
// interceptor both learn the device's identity and steer it onto its own
// control plane.
func TestMintPreauthKeyRefusesAnUnknownCA(t *testing.T) {
	deployment := newTestPKI(t)
	impostor := newTestPKI(t)
	endpoint := newFakeKeyEndpoint(t, impostor, "abc.tunnel.replycant.com", http.StatusOK)
	shim := newMintingShim(t, deployment, endpoint.addr(), "abc.tunnel.replycant.com")

	if _, err := shim.MintPreauthKey(mintContext(t)); err == nil {
		t.Fatal("a key from a control plane signed by an untrusted CA must be refused")
	}
	if requests, _ := endpoint.snapshot(); len(requests) != 0 {
		t.Errorf("no request should reach an untrusted server, got %v", requests)
	}
}

// hsproxy refuses keys while the repository is still in its bootstrap window.
// That has to come back as an error naming the status, not as an empty key the
// node would then try to log in with.
func TestMintPreauthKeyReportsARefusal(t *testing.T) {
	pki := newTestPKI(t)
	endpoint := newFakeKeyEndpoint(t, pki, "abc.tunnel.replycant.com", http.StatusForbidden)
	shim := newMintingShim(t, pki, endpoint.addr(), "abc.tunnel.replycant.com")

	_, err := shim.MintPreauthKey(mintContext(t))
	if err == nil {
		t.Fatal("a refused request must be an error")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Errorf("the error should name the status, got %v", err)
	}
}
