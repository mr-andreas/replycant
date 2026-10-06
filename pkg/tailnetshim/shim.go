// Package tailnetshim gives a Tailscale client a control-plane endpoint it is willing
// to talk to.
//
// The problem is narrow but blocking. replycant's headscale is fronted by
// hsproxy, which terminates TLS with a certificate from the deployment's own
// CA and requires a client certificate. A Tailscale client cannot be pointed at
// that directly: tsnet validates its control URL against the system trust
// store, and exposes no way to add a private root or present a client
// certificate for the control connection.
//
// So the client is pointed at plain HTTP on loopback instead, and this package
// performs the TLS it could not. Every connection accepted on loopback is
// relayed to the control plane over a TLS session that trusts only the
// deployment CA and presents the device's certificate. The client sees an
// ordinary HTTP endpoint; the network sees a properly authenticated mTLS
// session that the reverse tunnel cannot read.
//
// Binding loopback only is a security requirement rather than a convenience:
// the shim speaks with the device's credential, so anything that can reach it
// can reach the control plane as that device.
package tailnetshim

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/mr-andreas/replycant/pkg/netsplice"
)

// How long to wait for the control plane before giving up on one connection.
// The path crosses the hosted relay, so it is generous, but bounded: tsnet
// retries, and a hung dial would otherwise hold a goroutine and a socket.
const defaultDialTimeout = 30 * time.Second

// How long to spend on the in-tailnet route before falling back.
//
// Deliberately short. tsnet's Dial blocks until the node reaches Running, so
// this doubles as the guard against a node that has gone offline: the wait is
// paid once per connection and the relay picks up the session, rather than the
// device appearing to hang.
const tailnetDialTimeout = 2 * time.Second

// Which path a connection took, for diagnostics.
const (
	RouteTailnet = "tailnet"
	RouteRelay   = "relay"
)

// An in-tailnet path to the control plane, installed after the node is up.
//
// It cannot be part of Config because it does not exist yet at construction
// time: the node needs the shim's control URL in order to come up at all, so
// the first control session necessarily predates any tailnet route.
type TailnetRoute struct {
	// host:port of the control path inside the tailnet, dialled by name so
	// tsnet resolves it with MagicDNS. Nothing else knows tailnet names.
	Addr string

	// Verified against the certificate hsproxy presents on this path. Distinct
	// from the relay's server name: the same certificate carries both, and
	// sending the wrong one fails verification.
	ServerName string

	// Dials inside the tailnet, normally tsnet.Server.Dial. The shim performs
	// TLS over whatever this returns.
	Dial func(ctx context.Context, network, addr string) (net.Conn, error)
}

// How the shim reaches the deployment's control plane.
type Config struct {
	// host:port of the control plane. The tunnel hostname in cloud mode, or
	// the operator's own published address in manual-exposure mode.
	UpstreamAddr string

	// Name sent as SNI and verified against the presented certificate.
	//
	// Defaults to the host part of UpstreamAddr, which is what a deployment
	// normally wants. It is separate because the reverse tunnel routes purely
	// on SNI, so the name has to be right even when the dialled address is
	// not the name at all.
	UpstreamServerName string

	// The deployment's CA, and the only root the shim will trust. Falling back
	// to system roots would defeat the point.
	CAPEM []byte

	// The device's certificate, which is how hsproxy authorizes it against
	// pubkeys/. Without it every control-plane request is rejected.
	ClientCertificate tls.Certificate

	DialTimeout time.Duration

	// Optional. Defaults to the standard logger.
	Logf func(format string, args ...any)
}

// A running loopback endpoint that fronts the deployment's control plane.
type Shim struct {
	upstreamAddr       string
	upstreamServerName string
	dialTimeout        time.Duration
	tlsConfig          *tls.Config
	logf               func(format string, args ...any)

	mu           sync.Mutex
	listener     net.Listener
	closed       bool
	tailnetRoute *TailnetRoute
	tailnetTLS   *tls.Config
	lastRoute    string
}

// Validates the configuration and prepares the TLS parameters, so a bad
// deployment description fails before anything is listening.
func New(config Config) (*Shim, error) {
	upstreamAddr := strings.TrimSpace(config.UpstreamAddr)
	if upstreamAddr == "" {
		return nil, errors.New("shim: the control plane address is required")
	}
	host, _, err := net.SplitHostPort(upstreamAddr)
	if err != nil {
		return nil, fmt.Errorf("shim: control plane address must be host:port, got %q: %w",
			upstreamAddr, err)
	}

	if len(config.CAPEM) == 0 {
		return nil, errors.New("shim: the deployment CA is required; " +
			"falling back to system roots would let any public CA impersonate the control plane")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(config.CAPEM) {
		return nil, errors.New("shim: the deployment CA is not valid PEM-encoded certificate data")
	}

	if len(config.ClientCertificate.Certificate) == 0 {
		return nil, errors.New("shim: the device certificate is required; " +
			"the control plane authorizes devices by client certificate")
	}

	serverName := strings.TrimSpace(config.UpstreamServerName)
	if serverName == "" {
		serverName = host
	}

	dialTimeout := config.DialTimeout
	if dialTimeout <= 0 {
		dialTimeout = defaultDialTimeout
	}

	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}

	return &Shim{
		upstreamAddr:       upstreamAddr,
		upstreamServerName: serverName,
		dialTimeout:        dialTimeout,
		logf:               logf,
		tlsConfig: &tls.Config{
			RootCAs:      roots,
			ServerName:   serverName,
			Certificates: []tls.Certificate{config.ClientCertificate},
			MinVersion:   tls.VersionTLS12,
		},
	}, nil
}

// Binds the loopback listener.
//
// Separate from Serve so the caller can learn the port and build the control
// URL before any connection arrives. tsnet needs the URL at construction, so
// the alternative would be a fixed port and a startup race with whatever else
// is on the machine.
func (s *Shim) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.listener != nil {
		return errors.New("shim: already started")
	}
	if s.closed {
		return errors.New("shim: already closed")
	}

	// Port 0 lets the OS pick, which avoids colliding with anything else on a
	// user's machine. Loopback only: see the package comment.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("shim: listen on loopback: %w", err)
	}
	s.listener = listener
	return nil
}

// Accepts connections until the context is cancelled or the shim is closed.
func (s *Shim) Serve(ctx context.Context) {
	listener := s.currentListener()
	if listener == nil {
		return
	}

	// Cancellation reaches a blocked Accept only by closing the listener.
	go func() {
		<-ctx.Done()
		_ = s.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			// A closed listener is the normal shutdown path, not a failure.
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			s.logf("shim: accept failed: %v", err)
			return
		}
		go s.relay(ctx, conn)
	}
}

// Installs the in-tailnet path to the control plane, which later connections
// then prefer over the relay.
//
// Safe to call while serving, and expected to be: the sidecar calls it as soon
// as the node reaches Running, which is always after the shim has already
// carried at least one control session.
func (s *Shim) SetTailnetRoute(route TailnetRoute) error {
	addr := strings.TrimSpace(route.Addr)
	if addr == "" {
		return errors.New("shim: the tailnet route address is required")
	}
	if _, _, err := net.SplitHostPort(addr); err != nil {
		return fmt.Errorf("shim: tailnet route address must be host:port, got %q: %w",
			addr, err)
	}
	serverName := strings.TrimSpace(route.ServerName)
	if serverName == "" {
		return errors.New("shim: the tailnet route server name is required; " +
			"skipping verification would make this path the weakest one")
	}
	if route.Dial == nil {
		return errors.New("shim: the tailnet route needs a dialer, " +
			"since tailnet addresses are not reachable through the host stack")
	}

	// Same roots and same client identity as the relay path; only the name
	// being verified differs.
	tailnetTLS := s.tlsConfig.Clone()
	tailnetTLS.ServerName = serverName

	s.mu.Lock()
	defer s.mu.Unlock()
	s.tailnetRoute = &TailnetRoute{Addr: addr, ServerName: serverName, Dial: route.Dial}
	s.tailnetTLS = tailnetTLS
	return nil
}

// Which path the most recent connection took, or empty before the first one.
// Surfaced so the desktop app can tell a user whether they still depend on the
// hosted relay.
func (s *Shim) LastRoute() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastRoute
}

// Wraps one loopback connection in a mTLS session to the control plane.
func (s *Shim) relay(ctx context.Context, local net.Conn) {
	defer local.Close()

	upstream, route := s.dialControlPlane(ctx)
	if upstream == nil {
		// Closing the local side is what turns this into a clear failure for
		// the Tailscale client, which then retries with backoff.
		return
	}
	defer upstream.Close()

	s.mu.Lock()
	s.lastRoute = route
	s.mu.Unlock()

	// Bytes are copied verbatim in both directions. The Tailscale control
	// protocol upgrades a POST into a long-lived bidirectional stream, so
	// anything that tried to parse or buffer HTTP here would break it.
	netsplice.Splice(ctx, local, upstream, netsplice.Options{})
}

// Establishes a mTLS session to the control plane, preferring the tailnet.
//
// Returns a nil connection when both paths fail, having already logged why.
// The tailnet is tried first and briefly; the relay is what a device
// bootstraps through and what it falls back to when its own tailnet path is
// broken, so the relay attempt keeps the generous timeout.
func (s *Shim) dialControlPlane(ctx context.Context) (net.Conn, string) {
	s.mu.Lock()
	route, tailnetTLS := s.tailnetRoute, s.tailnetTLS
	s.mu.Unlock()

	if route != nil {
		conn, err := s.dialTailnet(ctx, *route, tailnetTLS)
		if err == nil {
			return conn, RouteTailnet
		}
		s.logf("shim: tailnet route to %s unavailable, falling back to %s: %v",
			route.Addr, s.upstreamAddr, err)
	}

	dialer := &tls.Dialer{
		NetDialer: &net.Dialer{Timeout: s.dialTimeout},
		Config:    s.tlsConfig,
	}
	dialCtx, cancel := context.WithTimeout(ctx, s.dialTimeout)
	defer cancel()

	conn, err := dialer.DialContext(dialCtx, "tcp", s.upstreamAddr)
	if err != nil {
		s.logf("shim: could not reach the control plane at %s: %v", s.upstreamAddr, err)
		return nil, ""
	}
	return conn, RouteRelay
}

// Performs the handshake over a connection the tailnet dialer produced.
//
// tls.Dialer cannot be used here because the dial has to go through tsnet's
// userspace stack rather than the host's, so TLS is layered on by hand.
func (s *Shim) dialTailnet(ctx context.Context, route TailnetRoute, tlsConfig *tls.Config) (net.Conn, error) {
	dialCtx, cancel := context.WithTimeout(ctx, tailnetDialTimeout)
	defer cancel()

	raw, err := route.Dial(dialCtx, "tcp", route.Addr)
	if err != nil {
		return nil, err
	}

	conn := tls.Client(raw, tlsConfig)
	if err := conn.HandshakeContext(dialCtx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return conn, nil
}

// The loopback address the Tailscale client should dial. Empty before Start.
func (s *Shim) Addr() string {
	listener := s.currentListener()
	if listener == nil {
		return ""
	}
	return listener.Addr().String()
}

// The control URL to hand to tsnet. Empty before Start.
//
// Plain http on purpose: this shim is the TLS layer, and asking tsnet for
// https here would have it validate a loopback certificate against system
// roots, which is the problem being worked around.
func (s *Shim) ControlURL() string {
	addr := s.Addr()
	if addr == "" {
		return ""
	}
	return "http://" + addr
}

// The name verified against the control plane's certificate, exposed so the
// caller can log what it is actually trusting.
func (s *Shim) UpstreamServerName() string {
	return s.upstreamServerName
}

// Releases the listener. Safe to call more than once, which matters because
// both Serve's cancellation goroutine and the caller's shutdown path call it.
func (s *Shim) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.closed = true
	if s.listener == nil {
		return nil
	}
	listener := s.listener
	s.listener = nil
	if err := listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
		return err
	}
	return nil
}

func (s *Shim) currentListener() net.Listener {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listener
}
