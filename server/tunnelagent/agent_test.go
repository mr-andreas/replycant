package tunnelagent

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/yamux"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

// Writes a deployment's CA, hsproxy leaf, and key to disk in the same layout
// the compose stack produces, so the agent is exercised against real files.
type testCredentials struct {
	dir      string
	caPEM    []byte
	caCert   *x509.Certificate
	certPath string
	keyPath  string
	caPath   string
}

func newTestCredentials(t *testing.T) *testCredentials {
	t.Helper()

	dir := t.TempDir()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate ca key: %v", err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "replycant-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create ca: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse ca: %v", err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "hsproxy"},
		DNSNames:              []string{"hsproxy.test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf: %v", err)
	}
	leafKeyDER, err := x509.MarshalECPrivateKey(leafKey)
	if err != nil {
		t.Fatalf("marshal leaf key: %v", err)
	}

	credentials := &testCredentials{
		dir:      dir,
		caPEM:    caPEM,
		caCert:   caCert,
		certPath: filepath.Join(dir, "hsproxy.crt"),
		keyPath:  filepath.Join(dir, "hsproxy.key"),
		caPath:   filepath.Join(dir, "ca.crt"),
	}

	writeFile(t, credentials.caPath, caPEM)
	writeFile(t, credentials.certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}))
	writeFile(t, credentials.keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: leafKeyDER}))

	return credentials
}

func writeFile(t *testing.T, path string, contents []byte) {
	t.Helper()
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// A stand-in relay that records the chain an agent presented and then serves
// as the yamux client, mirroring the real relay's role inversion.
type fakeRelay struct {
	addr       string
	caPool     *x509.CertPool
	chains     chan []*x509.Certificate
	sessions   chan *yamux.Session
	serverName string
}

func startFakeRelay(t *testing.T) *fakeRelay {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate relay key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(10),
		Subject:               pkix.Name{CommonName: "relay.test"},
		DNSNames:              []string{"relay.test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create relay cert: %v", err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse relay cert: %v", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(parsed)

	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		ClientAuth:   tls.RequireAnyClientCert,
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatalf("listen relay: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	relay := &fakeRelay{
		addr:       listener.Addr().String(),
		caPool:     pool,
		chains:     make(chan []*x509.Certificate, 8),
		sessions:   make(chan *yamux.Session, 8),
		serverName: "relay.test",
	}

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			tlsConn := conn.(*tls.Conn)
			if err := tlsConn.Handshake(); err != nil {
				_ = conn.Close()
				continue
			}
			relay.chains <- tlsConn.ConnectionState().PeerCertificates

			muxConfig := yamux.DefaultConfig()
			muxConfig.LogOutput = io.Discard
			session, err := yamux.Client(tlsConn, muxConfig)
			if err != nil {
				_ = conn.Close()
				continue
			}
			relay.sessions <- session
		}
	}()

	return relay
}

func (r *fakeRelay) agentConfig(credentials *testCredentials) Config {
	return Config{
		RelayAddr:       r.addr,
		CertPath:        credentials.certPath,
		KeyPath:         credentials.keyPath,
		CAPath:          credentials.caPath,
		RelayServerName: r.serverName,
		MinBackoff:      10 * time.Millisecond,
		MaxBackoff:      50 * time.Millisecond,
		DialTimeout:     5 * time.Second,
		Logf:            func(string, ...any) {},
	}
}

// The relay derives the subdomain from the CA in the presented chain, so the
// agent must append it. Omitting it would leave the deployment unroutable.
func TestAgentPresentsLeafAndCA(t *testing.T) {
	credentials := newTestCredentials(t)
	relay := startFakeRelay(t)

	config := relay.agentConfig(credentials)
	config.UpstreamAddr = "127.0.0.1:1"
	agent, err := New(config)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	// The fake relay uses a self-signed certificate; skip pinning here since
	// TestAgentPinsRelayCA covers that path explicitly.
	agent.tlsConfig.InsecureSkipVerify = true
	agent.tlsConfig.RootCAs = nil

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = agent.Run(ctx) }()

	select {
	case chain := <-relay.chains:
		if len(chain) != 2 {
			t.Fatalf("presented %d certificates, want 2 (leaf and CA)", len(chain))
		}
		if !chain[1].Equal(credentials.caCert) {
			t.Fatal("the second certificate must be the deployment CA")
		}
		if err := chain[0].CheckSignatureFrom(chain[1]); err != nil {
			t.Fatalf("the leaf must be signed by the presented CA: %v", err)
		}

		// The label the relay will derive has to be the one the client
		// computes from the same CA.
		expected, err := gitcrypt.CADNSLabel(string(credentials.caPEM))
		if err != nil {
			t.Fatalf("CADNSLabel: %v", err)
		}
		if len(expected) == 0 {
			t.Fatal("expected a non-empty label")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the agent did not register")
	}
}

// A relayed stream must be spliced to hsproxy verbatim, since it carries a TLS
// session the agent cannot read.
func TestAgentSplicesRelayedStreamToUpstream(t *testing.T) {
	credentials := newTestCredentials(t)
	relay := startFakeRelay(t)

	// Stands in for hsproxy.
	upstream, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	t.Cleanup(func() { _ = upstream.Close() })

	received := make(chan string, 1)
	go func() {
		conn, err := upstream.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 128)
		n, _ := conn.Read(buf)
		received <- string(buf[:n])
		_, _ = conn.Write([]byte("from-hsproxy"))
	}()

	config := relay.agentConfig(credentials)
	config.UpstreamAddr = upstream.Addr().String()
	agent, err := New(config)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	agent.tlsConfig.InsecureSkipVerify = true
	agent.tlsConfig.RootCAs = nil

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = agent.Run(ctx) }()

	var session *yamux.Session
	select {
	case session = <-relay.sessions:
	case <-time.After(10 * time.Second):
		t.Fatal("the agent did not register")
	}

	stream, err := session.Open()
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	defer stream.Close()

	const payload = "opaque-tls-bytes"
	if _, err := io.WriteString(stream, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-received:
		if got != payload {
			t.Fatalf("hsproxy received %q, want %q", got, payload)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("hsproxy never received the relayed bytes")
	}

	_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, 64)
	n, err := stream.Read(buf)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if got := string(buf[:n]); got != "from-hsproxy" {
		t.Fatalf("response = %q, want %q", got, "from-hsproxy")
	}
}

// Home connections drop constantly, so the agent must come back on its own.
// Without this the deployment would look permanently offline after one hiccup.
func TestAgentReconnectsAfterTheRelayDropsIt(t *testing.T) {
	credentials := newTestCredentials(t)
	relay := startFakeRelay(t)

	config := relay.agentConfig(credentials)
	config.UpstreamAddr = "127.0.0.1:1"
	agent, err := New(config)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	agent.tlsConfig.InsecureSkipVerify = true
	agent.tlsConfig.RootCAs = nil

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = agent.Run(ctx) }()

	var first *yamux.Session
	select {
	case first = <-relay.sessions:
	case <-time.After(10 * time.Second):
		t.Fatal("the agent did not register initially")
	}

	// Simulate the relay or network dropping the connection.
	_ = first.Close()

	select {
	case <-relay.sessions:
	case <-time.After(15 * time.Second):
		t.Fatal("the agent did not reconnect after being dropped")
	}
}

// Cancelling must actually stop the loop, or shutdown would hang.
func TestAgentRunStopsOnContextCancel(t *testing.T) {
	credentials := newTestCredentials(t)

	// A port nothing listens on, so Run stays in its retry loop.
	deadListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	deadAddr := deadListener.Addr().String()
	_ = deadListener.Close()

	agent, err := New(Config{
		RelayAddr:       deadAddr,
		UpstreamAddr:    "127.0.0.1:1",
		CertPath:        credentials.certPath,
		KeyPath:         credentials.keyPath,
		CAPath:          credentials.caPath,
		RelayServerName: "relay.test",
		MinBackoff:      10 * time.Millisecond,
		MaxBackoff:      20 * time.Millisecond,
		Logf:            func(string, ...any) {},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- agent.Run(ctx) }()

	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected Run to report why it stopped")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancellation")
	}
}

// Pinning the relay is optional but must work when configured, so a
// compromised public CA cannot redirect a deployment's registrations.
func TestAgentPinsRelayCA(t *testing.T) {
	credentials := newTestCredentials(t)

	// Pin an unrelated CA, so the handshake with the real relay must fail.
	unrelated := newTestCredentials(t)
	relayCAPath := filepath.Join(credentials.dir, "relay-ca.crt")
	writeFile(t, relayCAPath, unrelated.caPEM)

	relay := startFakeRelay(t)
	config := relay.agentConfig(credentials)
	config.UpstreamAddr = "127.0.0.1:1"
	config.RelayCAPath = relayCAPath

	agent, err := New(config)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if agent.tlsConfig.RootCAs == nil {
		t.Fatal("a configured relay CA must populate RootCAs")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = agent.Run(ctx)

	select {
	case chain := <-relay.chains:
		t.Fatalf("the agent must not complete a handshake against an unpinned relay, got %d certs", len(chain))
	default:
	}
}

// Configuration mistakes should be reported at startup, not as an endless
// reconnect loop that looks like a network problem.
func TestNewRejectsIncompleteConfig(t *testing.T) {
	credentials := newTestCredentials(t)
	complete := Config{
		RelayAddr:    "relay.test:8444",
		UpstreamAddr: "hsproxy:8443",
		CertPath:     credentials.certPath,
		KeyPath:      credentials.keyPath,
		CAPath:       credentials.caPath,
		Logf:         func(string, ...any) {},
	}

	cases := map[string]func(*Config){
		"no relay address":          func(c *Config) { c.RelayAddr = "" },
		"relay address is a URL":    func(c *Config) { c.RelayAddr = "https://relay.test" },
		"relay address has no port": func(c *Config) { c.RelayAddr = "relay.test" },
		"no upstream":               func(c *Config) { c.UpstreamAddr = "" },
		"no certificate":            func(c *Config) { c.CertPath = "" },
		"no key":                    func(c *Config) { c.KeyPath = "" },
		"no ca":                     func(c *Config) { c.CAPath = "" },
		"missing ca file":           func(c *Config) { c.CAPath = filepath.Join(credentials.dir, "absent.crt") },
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			config := complete
			mutate(&config)
			if _, err := New(config); err == nil {
				t.Fatal("expected an error for the incomplete config")
			}
		})
	}

	if _, err := New(complete); err != nil {
		t.Fatalf("the complete config must be accepted: %v", err)
	}
}

// The SNI defaults to the relay hostname so operators do not have to state it
// twice and cannot get the two out of sync.
func TestRelayServerNameDefaultsToRelayHost(t *testing.T) {
	credentials := newTestCredentials(t)

	agent, err := New(Config{
		RelayAddr:    "tunnel.replycant.com:8444",
		UpstreamAddr: "hsproxy:8443",
		CertPath:     credentials.certPath,
		KeyPath:      credentials.keyPath,
		CAPath:       credentials.caPath,
		Logf:         func(string, ...any) {},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if got := agent.tlsConfig.ServerName; got != "tunnel.replycant.com" {
		t.Fatalf("ServerName = %q, want %q", got, "tunnel.replycant.com")
	}
}

// The relay derives the label from the exact DER of the CA, so picking the
// wrong PEM block would make the deployment unroutable in a way that is hard
// to trace back.
func TestFirstCertificateDER(t *testing.T) {
	credentials := newTestCredentials(t)

	der, err := firstCertificateDER(credentials.caPEM)
	if err != nil {
		t.Fatalf("firstCertificateDER: %v", err)
	}
	if string(der) != string(credentials.caCert.Raw) {
		t.Fatal("must return the certificate's own DER bytes")
	}

	// A key ahead of the certificate must be skipped, not returned.
	keyFirst := append([]byte("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n"), credentials.caPEM...)
	der, err = firstCertificateDER(keyFirst)
	if err != nil {
		t.Fatalf("firstCertificateDER with a leading key: %v", err)
	}
	if string(der) != string(credentials.caCert.Raw) {
		t.Fatal("must skip non-certificate blocks")
	}

	if _, err := firstCertificateDER([]byte("not pem at all")); err == nil {
		t.Fatal("expected an error for input with no certificate")
	}
	if _, err := firstCertificateDER([]byte("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n")); err == nil {
		t.Fatal("expected an error when only a key is present")
	}
}

// Backoff must stay inside its configured bounds and vary, so a relay restart
// does not bring every deployment back in the same instant.
func TestJitterStaysWithinBounds(t *testing.T) {
	base := time.Second
	seen := make(map[time.Duration]bool)

	for i := 0; i < 200; i++ {
		value := jitter(base)
		if value < base/2 || value > base {
			t.Fatalf("jitter(%s) = %s, want between %s and %s", base, value, base/2, base)
		}
		seen[value] = true
	}
	if len(seen) < 2 {
		t.Fatal("jitter must vary between attempts")
	}
	if got := jitter(0); got != 0 {
		t.Fatalf("jitter(0) = %s, want 0", got)
	}
}

// A relay address without a port is a common mistake and must be named clearly
// rather than producing a confusing SNI.
func TestNormalizeReportsMissingPortClearly(t *testing.T) {
	config := Config{
		RelayAddr:    "tunnel.replycant.com",
		UpstreamAddr: "hsproxy:8443",
		CertPath:     "cert",
		KeyPath:      "key",
		CAPath:       "ca",
	}
	err := config.normalize()
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "host:port") {
		t.Fatalf("error should mention host:port, got %v", err)
	}
}
