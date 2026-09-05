// Package hsproxy puts a replycant-CA mTLS front door in front of headscale.
//
// Headscale has no client-certificate support of its own, so on its own it
// would accept a control-plane connection from anyone who can reach it. Since
// the headscale listener is the one thing this deployment intentionally exposes
// to the internet (through the reverse TCP tunnel), it needs an authenticating
// hop in front of it.
//
// The proxy deliberately terminates TLS and then splices raw bytes instead of
// speaking HTTP. The Tailscale control protocol upgrades over a POST with an
// `Upgrade: tailscale-control-protocol` token, which most HTTP proxies mangle
// or refuse. Byte splicing sidesteps that whole class of problem and means the
// proxy needs no knowledge of the protocol it carries.
//
// Authorization reuses the same pubkeys/*.pub list that gates git access, so
// revoking a device in one place revokes its tailnet access too.
package hsproxy

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/server/gitd/auth"
)

// Signals that the repository has no branches yet. The first device cannot
// have a pubkey committed before it joins the tailnet, because the repository
// it would push to is only reachable over that tailnet. Treating bootstrap as
// authorized is what makes first-device setup possible at all; the window
// closes as soon as the initial push lands.
var ErrBootstrap = auth.ErrUnauthorizedBootstrap

// Decides whether a presented client certificate belongs to a known device.
// Kept as an interface so the proxy can be tested without a git repository,
// and so the production implementation stays gitd's existing authenticator.
type Authorizer interface {
	Authenticate(cert *x509.Certificate) (string, error)
}

// Configures a proxy instance. Every field except the optional tuning knobs is
// required, and New reports what is missing rather than failing later on a
// device connection, where the error would look like a client problem.
type Config struct {
	Authorizer   Authorizer
	UpstreamAddr string
	ServerCert   tls.Certificate

	// Bounds how long a peer may hold a connection without completing the
	// TLS handshake, so an idle or hostile dialer cannot pin resources.
	HandshakeTimeout time.Duration

	// Bounds the upstream dial so a wedged headscale surfaces as a closed
	// client connection rather than an indefinite hang.
	DialTimeout time.Duration

	Logf func(format string, args ...any)
}

// Terminates mTLS for headscale and relays authorized sessions to it.
type Proxy struct {
	authorizer   Authorizer
	upstreamAddr string
	tlsConfig    *tls.Config

	handshakeTimeout time.Duration
	dialTimeout      time.Duration
	logf             func(format string, args ...any)
}

const (
	defaultHandshakeTimeout = 15 * time.Second
	defaultDialTimeout      = 10 * time.Second
)

// Validates configuration and builds the TLS parameters shared by every
// accepted connection.
//
// ClientAuth is RequireAnyClientCert rather than RequireAndVerifyClientCert
// because device certificates are self-signed: authorization comes from the
// pubkeys list, not from a chain to our CA. Requiring *a* certificate still
// guarantees the authorizer always has a key to check.
func New(config Config) (*Proxy, error) {
	if config.Authorizer == nil {
		return nil, errors.New("hsproxy: authorizer is required")
	}
	if strings.TrimSpace(config.UpstreamAddr) == "" {
		return nil, errors.New("hsproxy: upstream address is required")
	}
	if len(config.ServerCert.Certificate) == 0 {
		return nil, errors.New("hsproxy: server certificate is required")
	}

	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}
	handshakeTimeout := config.HandshakeTimeout
	if handshakeTimeout <= 0 {
		handshakeTimeout = defaultHandshakeTimeout
	}
	dialTimeout := config.DialTimeout
	if dialTimeout <= 0 {
		dialTimeout = defaultDialTimeout
	}

	return &Proxy{
		authorizer:   config.Authorizer,
		upstreamAddr: config.UpstreamAddr,
		tlsConfig: &tls.Config{
			Certificates: []tls.Certificate{config.ServerCert},
			ClientAuth:   tls.RequireAnyClientCert,
			MinVersion:   tls.VersionTLS12,
		},
		handshakeTimeout: handshakeTimeout,
		dialTimeout:      dialTimeout,
		logf:             logf,
	}, nil
}

// Accepts connections until the listener is closed. Each connection is handled
// on its own goroutine so one slow handshake cannot stall enrollment for other
// devices.
func (p *Proxy) Serve(listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go p.handle(conn)
	}
}

// Authorizes one connection and, if it belongs to a known device, relays it to
// headscale. Anything unauthorized is closed without a reply, so an attacker
// probing the tunnel learns nothing about what is behind it.
func (p *Proxy) handle(rawConn net.Conn) {
	defer rawConn.Close()

	tlsConn := tls.Server(rawConn, p.tlsConfig)

	if err := rawConn.SetDeadline(time.Now().Add(p.handshakeTimeout)); err != nil {
		p.logf("hsproxy: set handshake deadline for %s: %v", rawConn.RemoteAddr(), err)
		return
	}
	if err := tlsConn.Handshake(); err != nil {
		p.logf("hsproxy: handshake with %s failed: %v", rawConn.RemoteAddr(), err)
		return
	}
	// Relaying has no fixed duration; the control connection is long-lived.
	if err := rawConn.SetDeadline(time.Time{}); err != nil {
		p.logf("hsproxy: clear deadline for %s: %v", rawConn.RemoteAddr(), err)
		return
	}

	peerCerts := tlsConn.ConnectionState().PeerCertificates
	if len(peerCerts) == 0 {
		p.logf("hsproxy: %s presented no client certificate", rawConn.RemoteAddr())
		return
	}

	username, err := p.authorizer.Authenticate(peerCerts[0])
	switch {
	case err == nil:
		p.logf("hsproxy: authorized %q from %s", username, rawConn.RemoteAddr())
	case errors.Is(err, ErrBootstrap):
		p.logf("hsproxy: allowing bootstrap client from %s (repository is empty)", rawConn.RemoteAddr())
	default:
		p.logf("hsproxy: rejected %s: %v", rawConn.RemoteAddr(), err)
		return
	}

	upstream, err := net.DialTimeout("tcp", p.upstreamAddr, p.dialTimeout)
	if err != nil {
		p.logf("hsproxy: dial headscale at %s: %v", p.upstreamAddr, err)
		return
	}
	defer upstream.Close()

	relay(tlsConn, upstream)
}

// Copies bytes in both directions until either side finishes, then tears both
// down. Closing both ends on the first completed direction is what stops a
// half-open session from lingering after headscale or the device goes away.
func relay(client net.Conn, upstream net.Conn) {
	done := make(chan struct{}, 2)

	go func() {
		_, _ = io.Copy(upstream, client)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		done <- struct{}{}
	}()

	<-done
}

// Serves an unauthenticated readiness endpoint. It is deliberately separate
// from the mTLS listener because the container runtime has no device identity
// to present, and must never be exposed through the tunnel.
func (p *Proxy) HealthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "ok")
	})
	return mux
}
