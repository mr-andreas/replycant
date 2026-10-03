package hsproxy

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/server/tailnet"
)

// Records what the proxy asked about so tests can assert that authorization
// happens before any upstream connection is attempted.
type recordingAuthorizer struct {
	mu       sync.Mutex
	calls    int
	username string
	err      error
}

func (a *recordingAuthorizer) Authenticate(cert *x509.Certificate) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.calls++
	if cert == nil {
		return "", errors.New("nil certificate")
	}
	return a.username, a.err
}

func (a *recordingAuthorizer) callCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.calls
}

// Minimal PKI for the tests: one CA that signs the proxy's server certificate,
// plus independent self-signed client identities, which is exactly the shape
// gitd already uses (server cert from the CA, client certs self-signed).
type testPKI struct {
	caCert     *x509.Certificate
	caKey      *ecdsa.PrivateKey
	serverPair tls.Certificate
}

func newTestPKI(t *testing.T) *testPKI {
	t.Helper()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate ca key: %v", err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "replycant-test-ca"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create ca cert: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse ca cert: %v", err)
	}

	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate server key: %v", err)
	}
	serverTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "hsproxy.test"},
		DNSNames:              []string{"hsproxy.test"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caCert, &serverKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create server cert: %v", err)
	}

	return &testPKI{
		caCert: caCert,
		caKey:  caKey,
		serverPair: tls.Certificate{
			Certificate: [][]byte{serverDER},
			PrivateKey:  serverKey,
		},
	}
}

// Builds a self-signed P-256 client identity, matching how devices generate
// their own mTLS material today.
func newClientIdentity(t *testing.T, commonName string) tls.Certificate {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate client key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(3),
		Subject:               pkix.Name{CommonName: commonName},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create client cert: %v", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// Stands up an upstream TCP listener that echoes an HTTP response so tests can
// prove bytes traversed the proxy without interpreting them.
func newEchoUpstream(t *testing.T, response string) (addr string, requests func() []string) {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	var mu sync.Mutex
	var seen []string

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buf := make([]byte, 4096)
				n, err := conn.Read(buf)
				if n > 0 {
					mu.Lock()
					seen = append(seen, string(buf[:n]))
					mu.Unlock()
					_, _ = io.WriteString(conn, response)
				}
				if err != nil {
					return
				}
			}(conn)
		}
	}()

	return listener.Addr().String(), func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), seen...)
	}
}

// Starts a proxy on an ephemeral port and returns its address.
func startProxy(t *testing.T, proxy *Proxy) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen proxy: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() { _ = proxy.Serve(listener) }()
	return listener.Addr().String()
}

// Dials the proxy with the given client identity, trusting the test CA.
func dialProxy(t *testing.T, addr string, pki *testPKI, clientCert *tls.Certificate) (*tls.Conn, error) {
	t.Helper()

	pool := x509.NewCertPool()
	pool.AddCert(pki.caCert)

	config := &tls.Config{
		RootCAs:    pool,
		ServerName: "hsproxy.test",
		MinVersion: tls.VersionTLS13,
	}
	if clientCert != nil {
		config.Certificates = []tls.Certificate{*clientCert}
	}

	dialer := &net.Dialer{Timeout: 5 * time.Second}
	rawConn, err := dialer.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	conn := tls.Client(rawConn, config)
	if err := conn.Handshake(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

// An authorized device must reach headscale, and the proxy must forward the
// request bytes untouched so the control protocol is unaffected.
func TestProxyForwardsAuthorizedClient(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
	authorizer := &recordingAuthorizer{username: "my-phone"}

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	request := "GET /key?v=90 HTTP/1.1\r\nHost: control.example\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatalf("write request: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if !strings.Contains(string(buf[:n]), "200 OK") {
		t.Fatalf("expected upstream response, got %q", string(buf[:n]))
	}

	seen := upstreamRequests()
	if len(seen) != 1 {
		t.Fatalf("expected 1 upstream request, got %d", len(seen))
	}
	if seen[0] != request {
		t.Fatalf("upstream saw modified bytes:\n got: %q\nwant: %q", seen[0], request)
	}
}

// An unknown device must be refused, and the proxy must not open an upstream
// connection for it, so headscale never sees unauthorized traffic.
func TestProxyRejectsUnauthorizedClient(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	authorizer := &recordingAuthorizer{err: errors.New("public key not authorized")}

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "stranger")))
	if err != nil {
		// TLS 1.3 may surface the rejection during or right after the
		// handshake; either way the client gets no usable session.
		return
	}
	defer conn.Close()

	_, _ = io.WriteString(conn, "GET /key HTTP/1.1\r\n\r\n")
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Read(make([]byte, 64)); err == nil {
		t.Fatal("expected the rejected connection to be closed without a response")
	}

	if got := len(upstreamRequests()); got != 0 {
		t.Fatalf("upstream must not be dialed for unauthorized clients, saw %d requests", got)
	}
	if authorizer.callCount() == 0 {
		t.Fatal("expected the authorizer to be consulted")
	}
}

// The first device has to join the tailnet before it can push any pubkeys,
// so bootstrap mode must be allowed through rather than treated as a failure.
func TestProxyAllowsBootstrapMode(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
	authorizer := &recordingAuthorizer{username: "bootstrap", err: ErrBootstrap}

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "first-device")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	if _, err := io.WriteString(conn, "GET /key HTTP/1.1\r\n\r\n"); err != nil {
		t.Fatalf("write request: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 128)); err != nil {
		t.Fatalf("bootstrap client should be forwarded: %v", err)
	}
	if got := len(upstreamRequests()); got != 1 {
		t.Fatalf("expected the bootstrap client to reach upstream, saw %d requests", got)
	}
}

// A client that presents no certificate at all must be refused by TLS itself,
// which keeps the unauthenticated case from ever reaching the authorizer.
func TestProxyRequiresClientCertificate(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, _ := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	authorizer := &recordingAuthorizer{username: "unused"}

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	addr := startProxy(t, proxy)
	conn, err := dialProxy(t, addr, pki, nil)
	if err == nil {
		// TLS 1.3 defers the certificate requirement to the first read.
		_, _ = io.WriteString(conn, "GET /key HTTP/1.1\r\n\r\n")
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, err = conn.Read(make([]byte, 64))
		_ = conn.Close()
	}
	if err == nil {
		t.Fatal("expected a certificate-less client to be refused")
	}
}

// The Tailscale control protocol upgrades over a POST with a non-standard
// Upgrade token. Splicing bytes rather than proxying HTTP is what keeps this
// working, so assert the unusual request survives verbatim.
func TestProxyPassesThroughControlProtocolUpgrade(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t,
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: tailscale-control-protocol\r\nConnection: Upgrade\r\n\r\n")
	authorizer := &recordingAuthorizer{username: "my-phone"}

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	upgrade := "POST /ts2021 HTTP/1.1\r\nHost: control.example\r\n" +
		"Upgrade: tailscale-control-protocol\r\nConnection: Upgrade\r\n" +
		"X-Tailscale-Handshake: AAAA\r\n\r\n"
	if _, err := io.WriteString(conn, upgrade); err != nil {
		t.Fatalf("write upgrade: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read upgrade response: %v", err)
	}
	if !strings.Contains(string(buf[:n]), "101 Switching Protocols") {
		t.Fatalf("expected the upgrade to be relayed, got %q", string(buf[:n]))
	}

	seen := upstreamRequests()
	if len(seen) != 1 || seen[0] != upgrade {
		t.Fatalf("upgrade request was not relayed verbatim: %q", seen)
	}
}

// A dead headscale must not leave the client hanging on a half-open session.
func TestProxyClosesClientWhenUpstreamUnavailable(t *testing.T) {
	pki := newTestPKI(t)
	authorizer := &recordingAuthorizer{username: "my-phone"}

	// Bind and immediately release a port so the address is almost certainly
	// refused rather than blackholed.
	deadListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	deadAddr := deadListener.Addr().String()
	_ = deadListener.Close()

	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: deadAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		return
	}
	defer conn.Close()

	_, _ = io.WriteString(conn, "GET /key HTTP/1.1\r\n\r\n")
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 64)); err == nil {
		t.Fatal("expected the client connection to close when upstream is down")
	}
}

// Misconfiguration should fail at startup rather than at the first device
// connection, when it would look like a client bug.
func TestNewRejectsIncompleteConfig(t *testing.T) {
	pki := newTestPKI(t)
	authorizer := &recordingAuthorizer{}

	cases := []struct {
		name   string
		config Config
	}{
		{"no authorizer", Config{UpstreamAddr: "127.0.0.1:8080", ServerCert: pki.serverPair}},
		{"no upstream", Config{Authorizer: authorizer, ServerCert: pki.serverPair}},
		{"no server cert", Config{Authorizer: authorizer, UpstreamAddr: "127.0.0.1:8080"}},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := New(testCase.config); err == nil {
				t.Fatal("expected an error for incomplete config")
			}
		})
	}
}

// Health checks must not require a client certificate, because the container
// runtime has no device identity to present.
func TestHealthListenerReportsReady(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, _ := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")

	proxy, err := New(Config{
		Authorizer:   &recordingAuthorizer{username: "x"},
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen health: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() { _ = http.Serve(listener, proxy.HealthHandler()) }()

	response, err := http.Get(fmt.Sprintf("http://%s/healthz", listener.Addr().String()))
	if err != nil {
		t.Fatalf("get healthz: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
}

// Stands in for headscale's key API, recording what hsproxy asked for so tests
// can assert on the tag and lifetime of the credential handed to a device.
type recordingMinter struct {
	mu       sync.Mutex
	calls    int
	tag      string
	validFor time.Duration
	key      string
	err      error
}

func (m *recordingMinter) MintPreauthKey(_ context.Context, tag string, validFor time.Duration) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	m.tag = tag
	m.validFor = validFor
	return m.key, m.err
}

func (m *recordingMinter) snapshot() (calls int, tag string, validFor time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls, m.tag, m.validFor
}

// Sends the key request a client would and parses the reply.
func requestPreauthKey(t *testing.T, conn *tls.Conn) (*http.Response, []byte) {
	t.Helper()

	request := "POST " + tailnetaddr.PreauthKeyPath + " HTTP/1.1\r\nHost: control.example\r\n" +
		"Content-Length: 0\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatalf("write key request: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("read key response: %v", err)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read key response body: %v", err)
	}
	return response, body
}

func newMintingProxy(t *testing.T, pki *testPKI, upstreamAddr string, authorizer Authorizer, minter Minter) *Proxy {
	t.Helper()
	proxy, err := New(Config{
		Authorizer:   authorizer,
		UpstreamAddr: upstreamAddr,
		ServerCert:   pki.serverPair,
		Minter:       minter,
	})
	if err != nil {
		t.Fatalf("new proxy: %v", err)
	}
	return proxy
}

// A device in pubkeys/ that headscale no longer knows, because its database was
// wiped or its node was deleted on revocation of another device, must be able
// to get back onto the tailnet without re-pairing. Its certificate is the
// whole credential, so hsproxy answers the key request itself and never
// forwards it to headscale's control endpoint.
func TestProxyMintsKeyForAuthorizedDevice(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	minter := &recordingMinter{key: "hskey-auth-fresh"}
	proxy := newMintingProxy(t, pki, upstreamAddr, &recordingAuthorizer{username: "my-phone"}, minter)

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	response, body := requestPreauthKey(t, conn)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("an authorized device must get a key, got %d: %s", response.StatusCode, body)
	}
	var decoded struct {
		PreauthKey string `json:"preauth_key"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("the key response must be JSON: %v (%s)", err, body)
	}
	if decoded.PreauthKey != "hskey-auth-fresh" {
		t.Errorf("expected the minted key, got %q", decoded.PreauthKey)
	}

	calls, tag, validFor := minter.snapshot()
	if calls != 1 || tag != tailnet.DeviceTag || validFor != tailnet.PreauthKeyTTL {
		t.Errorf("expected one device key with the standard TTL, got calls=%d tag=%q ttl=%v",
			calls, tag, validFor)
	}
	if got := len(upstreamRequests()); got != 0 {
		t.Errorf("the key request must not reach headscale's control endpoint, saw %d", got)
	}
}

// While the repository is empty, hsproxy lets any certificate through so the
// first device can join. That exemption must not extend to minting: otherwise
// anyone who learned the tunnel hostname could take a key, join, and push
// their own pubkey before the real first device does. The first device gets
// its key from the loopback-only CA page instead.
func TestProxyRefusesKeysDuringBootstrap(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	minter := &recordingMinter{key: "hskey-auth-never"}
	authorizer := &recordingAuthorizer{username: "bootstrap", err: ErrBootstrap}
	proxy := newMintingProxy(t, pki, upstreamAddr, authorizer, minter)

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "stranger")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	response, _ := requestPreauthKey(t, conn)
	if response.StatusCode != http.StatusForbidden {
		t.Errorf("bootstrap clients must be refused a key, got %d", response.StatusCode)
	}
	if calls, _, _ := minter.snapshot(); calls != 0 {
		t.Errorf("no key may be minted during bootstrap, minted %d", calls)
	}
	if got := len(upstreamRequests()); got != 0 {
		t.Errorf("the refused request must not reach headscale, saw %d", got)
	}
}

// An unknown certificate must get no key and no reply, exactly as for control
// traffic, so the minting path adds nothing an attacker can probe.
func TestProxyRefusesKeysToUnauthorizedClients(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, _ := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	minter := &recordingMinter{key: "hskey-auth-never"}
	authorizer := &recordingAuthorizer{err: errors.New("public key not authorized")}
	proxy := newMintingProxy(t, pki, upstreamAddr, authorizer, minter)

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "stranger")))
	if err == nil {
		defer conn.Close()
		_, _ = io.WriteString(conn, "POST "+tailnetaddr.PreauthKeyPath+" HTTP/1.1\r\n\r\n")
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		if _, err := conn.Read(make([]byte, 64)); err == nil {
			t.Fatal("an unauthorized client must get no reply")
		}
	}
	if calls, _, _ := minter.snapshot(); calls != 0 {
		t.Errorf("no key may be minted for an unauthorized client, minted %d", calls)
	}
}

// A headscale failure must reach the device as a failure it can retry, not as
// a closed connection that looks like being unauthorized.
func TestProxyReportsMintFailureAsBadGateway(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, _ := newEchoUpstream(t, "HTTP/1.1 200 OK\r\n\r\n")
	minter := &recordingMinter{err: errors.New("headscale returned 503")}
	proxy := newMintingProxy(t, pki, upstreamAddr, &recordingAuthorizer{username: "my-phone"}, minter)

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	response, body := requestPreauthKey(t, conn)
	if response.StatusCode != http.StatusBadGateway {
		t.Errorf("a headscale failure must surface as 502, got %d", response.StatusCode)
	}
	if strings.Contains(string(body), "503") {
		t.Errorf("headscale's internal error must not be echoed to the device, got %q", body)
	}
}

// hsproxy has to read the request line to recognise the key request, and a
// client may deliver it in more than one TLS record. Whatever was read while
// deciding must still reach headscale in full and in order, or the control
// protocol breaks for exactly the clients whose writes happen to be split.
func TestProxyForwardsRequestLineSplitAcrossWrites(t *testing.T) {
	pki := newTestPKI(t)
	upstreamAddr, upstreamRequests := newEchoUpstream(t, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
	proxy := newMintingProxy(t, pki, upstreamAddr, &recordingAuthorizer{username: "my-phone"},
		&recordingMinter{key: "unused"})

	conn, err := dialProxy(t, startProxy(t, proxy), pki, ptr(newClientIdentity(t, "my-phone")))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	if _, err := io.WriteString(conn, "GET /ke"); err != nil {
		t.Fatalf("write first fragment: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	rest := "y?v=90 HTTP/1.1\r\nHost: control.example\r\n\r\n"
	if _, err := io.WriteString(conn, rest); err != nil {
		t.Fatalf("write second fragment: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if !strings.Contains(string(buf[:n]), "200 OK") {
		t.Fatalf("expected upstream response, got %q", string(buf[:n]))
	}
	seen := strings.Join(upstreamRequests(), "")
	if seen != "GET /ke"+rest {
		t.Fatalf("upstream must see the request exactly once and in order, got %q", seen)
	}
}

func ptr[T any](value T) *T {
	return &value
}
