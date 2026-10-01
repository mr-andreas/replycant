package tailnetshim

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// A CA plus the leaf certificates a deployment issues from it, so tests can
// exercise the shim's trust decisions the way a real deployment would.
type testPKI struct {
	caPEM      []byte
	caCert     *x509.Certificate
	caKey      *ecdsa.PrivateKey
	clientCert tls.Certificate
}

func newTestPKI(t *testing.T) *testPKI {
	t.Helper()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "replycant test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse CA cert: %v", err)
	}

	pki := &testPKI{
		caPEM:  pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}),
		caCert: caCert,
		caKey:  caKey,
	}
	pki.clientCert = pki.issue(t, "device", nil)
	return pki
}

// Issues a leaf from the CA. dnsNames being empty produces a client
// certificate; supplying them produces a server certificate.
func (p *testPKI) issue(t *testing.T, commonName string, dnsNames []string) tls.Certificate {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		DNSNames:     dnsNames,
	}
	if len(dnsNames) > 0 {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	} else {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}

	der, err := x509.CreateCertificate(rand.Reader, template, p.caCert, &key.PublicKey, p.caKey)
	if err != nil {
		t.Fatalf("create leaf cert: %v", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// Stands in for hsproxy behind the tunnel: requires a client certificate, and
// echoes whatever it receives so tests can prove bytes survive intact.
type fakeHeadscale struct {
	listener net.Listener
	pki      *testPKI

	mu             sync.Mutex
	handshakes     int
	clientSubjects []string
	serverNames    []string
}

func newFakeHeadscale(t *testing.T, pki *testPKI, serverName string) *fakeHeadscale {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	fake := &fakeHeadscale{listener: listener, pki: pki}

	serverCert := pki.issue(t, serverName, []string{serverName})
	pool := x509.NewCertPool()
	pool.AddCert(pki.caCert)
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAnyClientCert,
		MinVersion:   tls.VersionTLS12,
	}

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go fake.serve(tls.Server(conn, tlsConfig))
		}
	}()
	t.Cleanup(func() { _ = listener.Close() })
	return fake
}

func (f *fakeHeadscale) serve(conn *tls.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := conn.Handshake(); err != nil {
		return
	}

	state := conn.ConnectionState()
	subject := ""
	if len(state.PeerCertificates) > 0 {
		subject = state.PeerCertificates[0].Subject.CommonName
	}
	f.mu.Lock()
	f.handshakes++
	f.clientSubjects = append(f.clientSubjects, subject)
	f.serverNames = append(f.serverNames, state.ServerName)
	f.mu.Unlock()

	_, _ = io.Copy(conn, conn)
}

func (f *fakeHeadscale) snapshot() (handshakes int, subjects, serverNames []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.handshakes, append([]string(nil), f.clientSubjects...), append([]string(nil), f.serverNames...)
}

func (f *fakeHeadscale) addr() string { return f.listener.Addr().String() }

// Brings up a shim and starts it accepting, which is the two-step sequence the
// sidecar performs: bind first so the control URL is known, then serve.
func startShim(t *testing.T, config Config) *Shim {
	t.Helper()

	shim, err := New(config)
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	if err := shim.Start(); err != nil {
		t.Fatalf("start shim: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan struct{})
	go func() {
		defer close(served)
		shim.Serve(ctx)
	}()

	t.Cleanup(func() {
		cancel()
		_ = shim.Close()
		<-served
	})
	return shim
}

func baseConfig(pki *testPKI, fake *fakeHeadscale, serverName string) Config {
	return Config{
		UpstreamAddr:       fake.addr(),
		UpstreamServerName: serverName,
		CAPEM:              pki.caPEM,
		ClientCertificate:  pki.clientCert,
	}
}

// The reason the shim exists: tsnet validates its control URL against system
// roots with no way to inject a private CA, so it speaks plain HTTP to
// loopback and the shim performs the TLS that trusts the replycant CA.
func TestShimListensOnLoopbackAndRelaysOverTLS(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	host, _, err := net.SplitHostPort(shim.Addr())
	if err != nil {
		t.Fatalf("split shim address %q: %v", shim.Addr(), err)
	}
	if host != "127.0.0.1" {
		t.Errorf("the shim must not be reachable off the machine, bound to %q", host)
	}

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))

	// Plain bytes in, plain bytes out. The client never performs TLS itself.
	payload := []byte("GET /key?v=120 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write through shim: %v", err)
	}
	echoed := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, echoed); err != nil {
		t.Fatalf("read through shim: %v", err)
	}
	if string(echoed) != string(payload) {
		t.Errorf("bytes must survive the shim intact, got %q", echoed)
	}

	handshakes, _, _ := fake.snapshot()
	if handshakes != 1 {
		t.Errorf("expected one upstream TLS handshake, got %d", handshakes)
	}
}

// The device's client certificate is how hsproxy authorizes it against
// pubkeys/. Without it every control-plane request would be rejected and the
// tailnet would never come up.
func TestShimPresentsTheDeviceCertificate(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write([]byte("x")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 1)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}

	_, subjects, _ := fake.snapshot()
	if len(subjects) != 1 || subjects[0] != "device" {
		t.Errorf("the shim must present the device certificate, upstream saw %v", subjects)
	}
}

// The relay routes by SNI, so the shim has to name the tunnel hostname even
// though it dialled a loopback socket. Sending the loopback name instead would
// be dropped by the relay as an unregistered label.
func TestShimSendsTheTunnelServerName(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write([]byte("x")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 1)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}

	_, _, serverNames := fake.snapshot()
	if len(serverNames) != 1 || serverNames[0] != "abc.tunnel.replycant.com" {
		t.Errorf("the shim must send the tunnel hostname as SNI, upstream saw %v", serverNames)
	}
}

// Drives one control connection through the shim and waits for the echo, so a
// test can then assert which upstream actually served it.
func exchange(t *testing.T, shim *Shim) error {
	t.Helper()

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	if _, err := conn.Write([]byte("x")); err != nil {
		return err
	}
	_, err = io.ReadFull(conn, make([]byte, 1))
	return err
}

// A dialer that records its use, standing in for tsnet.Server.Dial.
type countingDialer struct {
	mu    sync.Mutex
	calls int
	addrs []string
	dial  func(ctx context.Context, network, addr string) (net.Conn, error)
}

func (d *countingDialer) Dial(ctx context.Context, network, addr string) (net.Conn, error) {
	d.mu.Lock()
	d.calls++
	d.addrs = append(d.addrs, addr)
	d.mu.Unlock()
	return d.dial(ctx, network, addr)
}

func (d *countingDialer) snapshot() (calls int, addrs []string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.calls, append([]string(nil), d.addrs...)
}

// Once the device is a tailnet member it should reach the control plane over
// the tailnet, not back out through the hosted relay. Preferring the tailnet
// route is what turns the relay into a bootstrap dependency rather than a
// permanent one.
func TestTailnetRouteIsPreferredOnceSet(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	// The in-tailnet path terminates at the same hsproxy, which presents the
	// same certificate under its tailnet name.
	overTailnet := newFakeHeadscale(t, pki, "gitd.replycant.internal")

	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))

	dialer := &countingDialer{dial: func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, overTailnet.addr())
	}}
	if err := shim.SetTailnetRoute(TailnetRoute{
		Addr:       "gitd.replycant.internal:8444",
		ServerName: "gitd.replycant.internal",
		Dial:       dialer.Dial,
	}); err != nil {
		t.Fatalf("set the tailnet route: %v", err)
	}

	if err := exchange(t, shim); err != nil {
		t.Fatalf("the tailnet route must carry the connection: %v", err)
	}

	if handshakes, _, _ := overTailnet.snapshot(); handshakes != 1 {
		t.Errorf("expected the tailnet upstream to serve the connection, got %d handshakes",
			handshakes)
	}
	if handshakes, _, _ := relay.snapshot(); handshakes != 0 {
		t.Errorf("the relay must not be used once the tailnet route works, got %d handshakes",
			handshakes)
	}

	// The route is dialled by name so tsnet resolves it with MagicDNS, which
	// is the only resolver that knows tailnet names.
	calls, addrs := dialer.snapshot()
	if calls != 1 || len(addrs) != 1 || addrs[0] != "gitd.replycant.internal:8444" {
		t.Errorf("expected one dial to the tailnet name, got %d calls to %v", calls, addrs)
	}
	if shim.LastRoute() != RouteTailnet {
		t.Errorf("LastRoute() = %q, want %q", shim.LastRoute(), RouteTailnet)
	}
}

// The tailnet route depends on the node being up and the server being online,
// neither of which is guaranteed. Falling back keeps a device connectable
// instead of stranding it when its own tailnet path is broken.
func TestFailingTailnetRouteFallsBackToTheRelay(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))

	dialer := &countingDialer{dial: func(context.Context, string, string) (net.Conn, error) {
		return nil, errors.New("tailnet is not up")
	}}
	if err := shim.SetTailnetRoute(TailnetRoute{
		Addr:       "gitd.replycant.internal:8444",
		ServerName: "gitd.replycant.internal",
		Dial:       dialer.Dial,
	}); err != nil {
		t.Fatalf("set the tailnet route: %v", err)
	}

	if err := exchange(t, shim); err != nil {
		t.Fatalf("a failed tailnet route must fall back to the relay: %v", err)
	}

	if calls, _ := dialer.snapshot(); calls != 1 {
		t.Errorf("expected the tailnet route to be tried once, got %d", calls)
	}
	if handshakes, _, _ := relay.snapshot(); handshakes != 1 {
		t.Errorf("expected the relay to serve the fallback, got %d handshakes", handshakes)
	}
	if shim.LastRoute() != RouteRelay {
		t.Errorf("LastRoute() = %q, want %q", shim.LastRoute(), RouteRelay)
	}
}

// An hsproxy certificate missing the tailnet SAN is indistinguishable from an
// interception attempt on that path, so the tailnet route must refuse it and
// let the relay carry the session rather than relaxing verification.
func TestTailnetRouteVerifiesItsOwnServerName(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	// Serves only the tunnel name, as an older deployment's certificate would.
	overTailnet := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")

	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))
	if err := shim.SetTailnetRoute(TailnetRoute{
		Addr:       "gitd.replycant.internal:8444",
		ServerName: "gitd.replycant.internal",
		Dial: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, overTailnet.addr())
		},
	}); err != nil {
		t.Fatalf("set the tailnet route: %v", err)
	}

	if err := exchange(t, shim); err != nil {
		t.Fatalf("the relay must still carry the session: %v", err)
	}
	if handshakes, _, _ := relay.snapshot(); handshakes != 1 {
		t.Errorf("expected the relay to serve the session, got %d handshakes", handshakes)
	}
}

// Before the node is up there is no tailnet to dial, and tsnet's Dial blocks
// waiting for one. Attempting it anyway would add the tailnet dial timeout to
// every control connection during the join that has to happen first.
func TestNoTailnetAttemptBeforeTheRouteIsSet(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))

	if err := exchange(t, shim); err != nil {
		t.Fatalf("bootstrap must work with no tailnet route: %v", err)
	}
	if handshakes, _, _ := relay.snapshot(); handshakes != 1 {
		t.Errorf("expected the relay to serve the bootstrap, got %d handshakes", handshakes)
	}
	if shim.LastRoute() != RouteRelay {
		t.Errorf("LastRoute() = %q, want %q", shim.LastRoute(), RouteRelay)
	}
}

// Nothing has used a route yet before the first connection, and the status UI
// distinguishes that from having fallen back to the relay.
func TestLastRouteIsEmptyBeforeAnyConnection(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))

	if route := shim.LastRoute(); route != "" {
		t.Errorf("LastRoute() = %q before any connection, want empty", route)
	}
}

// An incomplete route would silently never be used, or be used without
// verifying a name, so it is rejected where the mistake was made.
func TestSetTailnetRouteRejectsAnIncompleteRoute(t *testing.T) {
	pki := newTestPKI(t)
	relay := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, relay, "abc.tunnel.replycant.com"))

	dial := func(context.Context, string, string) (net.Conn, error) { return nil, nil }
	cases := map[string]TailnetRoute{
		"no address":     {ServerName: "gitd.replycant.internal", Dial: dial},
		"no server name": {Addr: "gitd.replycant.internal:8444", Dial: dial},
		"no dialer":      {Addr: "gitd.replycant.internal:8444", ServerName: "gitd.replycant.internal"},
		"address is not host:port": {
			Addr: "gitd.replycant.internal", ServerName: "gitd.replycant.internal", Dial: dial,
		},
	}
	for name, route := range cases {
		t.Run(name, func(t *testing.T) {
			if err := shim.SetTailnetRoute(route); err == nil {
				t.Fatal("expected an incomplete route to be rejected")
			}
		})
	}
}

// The whole security value of the shim is that it pins the deployment's CA.
// A control plane presenting anything else is an interception attempt, and the
// connection must fail rather than fall back to system roots.
func TestShimRefusesAnUnknownCA(t *testing.T) {
	deployment := newTestPKI(t)
	impostor := newTestPKI(t)
	fake := newFakeHeadscale(t, impostor, "abc.tunnel.replycant.com")

	// Trust the deployment CA while the upstream is signed by another one.
	config := baseConfig(deployment, fake, "abc.tunnel.replycant.com")
	shim := startShim(t, config)

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))

	if _, err := conn.Write([]byte("x")); err != nil {
		// A write may succeed into the local buffer; the read below is the
		// assertion that matters.
		t.Logf("write returned %v", err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 1)); err == nil {
		t.Fatal("the shim must not relay to a control plane signed by an untrusted CA")
	}

	if handshakes, _, _ := fake.snapshot(); handshakes != 0 {
		t.Errorf("no upstream handshake should have completed, got %d", handshakes)
	}
}

// A certificate valid for a different name is the same failure as an unknown
// CA: it means something other than this deployment's control plane answered.
func TestShimRefusesAHostnameMismatch(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "someone-else.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	_, _ = conn.Write([]byte("x"))

	if _, err := io.ReadFull(conn, make([]byte, 1)); err == nil {
		t.Fatal("the shim must reject a certificate issued for another hostname")
	}
}

// tsnet opens more than one control connection over a session, so the shim has
// to keep serving rather than handling one and stopping.
func TestShimServesManyConnections(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	const connections = 5
	for i := range connections {
		conn, err := net.Dial("tcp", shim.Addr())
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		message := fmt.Sprintf("hello-%d", i)
		if _, err := conn.Write([]byte(message)); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		echoed := make([]byte, len(message))
		if _, err := io.ReadFull(conn, echoed); err != nil {
			t.Fatalf("read %d: %v", i, err)
		}
		if string(echoed) != message {
			t.Errorf("connection %d got %q", i, echoed)
		}
		_ = conn.Close()
	}

	if handshakes, _, _ := fake.snapshot(); handshakes != connections {
		t.Errorf("expected %d upstream handshakes, got %d", connections, handshakes)
	}
}

// The control URL has to be handed to tsnet, so it must be a URL rather than a
// bare address, and it must be plain http because the shim is the TLS layer.
func TestControlURLIsPlainHTTPLoopback(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	controlURL := shim.ControlURL()
	if !strings.HasPrefix(controlURL, "http://127.0.0.1:") {
		t.Errorf("tsnet needs a plain-http loopback control URL, got %q", controlURL)
	}
	if strings.HasSuffix(controlURL, "/") {
		t.Errorf("a trailing slash would produce doubled paths, got %q", controlURL)
	}
}

// Closing must release the port. Electron restarts the sidecar on
// reconfiguration, and a leaked listener would make the restart fail.
func TestCloseReleasesThePort(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")

	shim, err := New(baseConfig(pki, fake, "abc.tunnel.replycant.com"))
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	if err := shim.Start(); err != nil {
		t.Fatalf("start shim: %v", err)
	}
	addr := shim.Addr()
	if err := shim.Close(); err != nil {
		t.Fatalf("close shim: %v", err)
	}

	// Rebinding the exact port proves it was released rather than lingering.
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("the shim's port must be free after Close: %v", err)
	}
	_ = listener.Close()

	// Closing twice happens on a failed startup path and must not panic.
	if err := shim.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
		t.Errorf("a second Close must be harmless, got %v", err)
	}
}

// Each field is required to make a trusted connection, so an incomplete config
// fails at construction rather than producing a shim that silently cannot
// reach anything.
func TestNewRejectsIncompleteConfig(t *testing.T) {
	pki := newTestPKI(t)
	complete := Config{
		UpstreamAddr:       "abc.tunnel.replycant.com:443",
		UpstreamServerName: "abc.tunnel.replycant.com",
		CAPEM:              pki.caPEM,
		ClientCertificate:  pki.clientCert,
	}

	for _, testCase := range []struct {
		name   string
		mutate func(*Config)
	}{
		{"no upstream address", func(c *Config) { c.UpstreamAddr = "" }},
		{"no CA", func(c *Config) { c.CAPEM = nil }},
		{"unparseable CA", func(c *Config) { c.CAPEM = []byte("not a certificate") }},
		{"no client certificate", func(c *Config) { c.ClientCertificate = tls.Certificate{} }},
		{"upstream address without a port", func(c *Config) { c.UpstreamAddr = "abc.tunnel.replycant.com" }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			config := complete
			testCase.mutate(&config)
			if _, err := New(config); err == nil {
				t.Fatal("an incomplete config must be rejected")
			}
		})
	}
}

// The server name is what the relay routes on, and it is almost always the
// upstream host. Defaulting it removes a way to misconfigure the sidecar.
func TestUpstreamServerNameDefaultsToTheUpstreamHost(t *testing.T) {
	pki := newTestPKI(t)
	shim, err := New(Config{
		UpstreamAddr:      "abc.tunnel.replycant.com:443",
		CAPEM:             pki.caPEM,
		ClientCertificate: pki.clientCert,
	})
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	if got := shim.UpstreamServerName(); got != "abc.tunnel.replycant.com" {
		t.Errorf("expected the upstream host as the default server name, got %q", got)
	}
}

// An unreachable control plane must surface as a closed connection rather than
// hanging, so tsnet's join fails with an error instead of blocking startup.
func TestUnreachableUpstreamClosesTheConnection(t *testing.T) {
	pki := newTestPKI(t)

	// Port 1 on loopback is not listening, which makes the dial fail fast.
	shim := startShim(t, Config{
		UpstreamAddr:       "127.0.0.1:1",
		UpstreamServerName: "abc.tunnel.replycant.com",
		CAPEM:              pki.caPEM,
		ClientCertificate:  pki.clientCert,
		DialTimeout:        2 * time.Second,
	})

	conn, err := net.Dial("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("dial shim: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	_, _ = conn.Write([]byte("x"))

	if _, err := io.ReadFull(conn, make([]byte, 1)); err == nil {
		t.Fatal("an unreachable upstream must not look like a working connection")
	}
}

// Start must be callable once. A second call would bind a second port and
// leave the first leaked, so it is reported rather than silently accepted.
func TestStartIsNotRepeatable(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	if err := shim.Start(); err == nil {
		t.Fatal("starting an already-started shim must be reported")
	}
}

// Addr and ControlURL are read by the caller before it hands the URL to tsnet,
// so calling them on an unstarted shim has to be an obvious empty value rather
// than a panic.
func TestAddrIsEmptyBeforeStart(t *testing.T) {
	pki := newTestPKI(t)
	shim, err := New(Config{
		UpstreamAddr:      "abc.tunnel.replycant.com:443",
		CAPEM:             pki.caPEM,
		ClientCertificate: pki.clientCert,
	})
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	if shim.Addr() != "" {
		t.Errorf("an unstarted shim has no address, got %q", shim.Addr())
	}
	if shim.ControlURL() != "" {
		t.Errorf("an unstarted shim has no control URL, got %q", shim.ControlURL())
	}
}

// Confirms the CA parser accepts a real multi-block PEM file, which is what a
// deployment's ca.crt looks like once an intermediate is added.
func TestCAPEMAcceptsMultipleCertificates(t *testing.T) {
	first := newTestPKI(t)
	second := newTestPKI(t)
	combined := append(append([]byte(nil), first.caPEM...), second.caPEM...)

	if _, err := New(Config{
		UpstreamAddr:      "abc.tunnel.replycant.com:443",
		CAPEM:             combined,
		ClientCertificate: first.clientCert,
	}); err != nil {
		t.Fatalf("a bundle of CA certificates must be accepted: %v", err)
	}
}

// Guards against the shim being reachable from other machines. Binding to a
// wildcard address would turn a device's own credential into a shared proxy
// anyone on the LAN could use to reach the control plane.
func TestShimNeverBindsAWildcardAddress(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")
	shim := startShim(t, baseConfig(pki, fake, "abc.tunnel.replycant.com"))

	addr, err := net.ResolveTCPAddr("tcp", shim.Addr())
	if err != nil {
		t.Fatalf("resolve shim address: %v", err)
	}
	if !addr.IP.IsLoopback() {
		t.Errorf("the shim must bind loopback only, bound to %s", addr.IP)
	}
}

// Context cancellation is how Electron stops the sidecar, and it must tear the
// listener down rather than leaving it accepting.
func TestServeStopsOnContextCancellation(t *testing.T) {
	pki := newTestPKI(t)
	fake := newFakeHeadscale(t, pki, "abc.tunnel.replycant.com")

	shim, err := New(baseConfig(pki, fake, "abc.tunnel.replycant.com"))
	if err != nil {
		t.Fatalf("build shim: %v", err)
	}
	if err := shim.Start(); err != nil {
		t.Fatalf("start shim: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		shim.Serve(ctx)
		close(done)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Serve must return once its context is cancelled")
	}
}
