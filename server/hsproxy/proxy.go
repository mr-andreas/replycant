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
// The one exception is the pre-auth key request. headscale's database is a
// cache of pubkeys/, so a device it has forgotten must be able to get back on
// with nothing but its certificate. hsproxy is the only service such a device
// can reach, so it reads the request line of each session and answers a key
// request itself; every other session is spliced byte for byte, including the
// bytes read while deciding.
//
// Authorization reuses the same pubkeys/*.pub list that gates git access, so
// revoking a device in one place revokes its tailnet access too.
package hsproxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/mr-andreas/replycant/server/tailnet"
)

// How long a key request may wait on headscale. A device retries on failure,
// so failing fast beats holding its join open.
const mintTimeout = 15 * time.Second

// Bounds the request line hsproxy will buffer while deciding where a session
// goes. Real request lines are far shorter; anything longer is spliced
// untouched rather than buffered without limit.
const maxRequestLineBytes = 4096

// The request line that identifies a key request. Matched as a prefix of the
// raw line so the HTTP version does not matter.
var preauthKeyRequestLine = []byte("POST " + tailnetaddr.PreauthKeyPath + " ")

// Mints the single-use key an authorized device joins with. An interface so
// the proxy can be tested without headscale; production uses tailnet.Client.
type Minter interface {
	MintPreauthKey(ctx context.Context, tag string, validFor time.Duration) (string, error)
}

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

	// Optional. Without it, key requests are answered 404, which is only
	// right for tests and deployments that never lose headscale state.
	Minter Minter

	Logf func(format string, args ...any)
}

// Terminates mTLS for headscale and relays authorized sessions to it.
type Proxy struct {
	authorizer   Authorizer
	upstreamAddr string
	tlsConfig    *tls.Config
	minter       Minter

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
		minter:           config.Minter,
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
	bootstrap := false
	switch {
	case err == nil:
		p.logf("hsproxy: authorized %q from %s", username, rawConn.RemoteAddr())
	case errors.Is(err, ErrBootstrap):
		bootstrap = true
		p.logf("hsproxy: allowing bootstrap client from %s (repository is empty)", rawConn.RemoteAddr())
	default:
		p.logf("hsproxy: rejected %s: %v", rawConn.RemoteAddr(), err)
		return
	}

	// HTTP clients speak first, so the request line arrives promptly. The
	// deadline only stops a silent peer from holding the session open.
	if err := rawConn.SetReadDeadline(time.Now().Add(p.handshakeTimeout)); err != nil {
		p.logf("hsproxy: set request deadline for %s: %v", rawConn.RemoteAddr(), err)
		return
	}
	reader := bufio.NewReaderSize(tlsConn, maxRequestLineBytes)
	isKeyRequest, err := peekKeyRequest(reader)
	if err != nil {
		p.logf("hsproxy: read request from %s: %v", rawConn.RemoteAddr(), err)
		return
	}
	if err := rawConn.SetReadDeadline(time.Time{}); err != nil {
		p.logf("hsproxy: clear request deadline for %s: %v", rawConn.RemoteAddr(), err)
		return
	}

	if isKeyRequest {
		p.serveKeyRequest(tlsConn, reader, username, bootstrap)
		return
	}

	upstream, err := net.DialTimeout("tcp", p.upstreamAddr, p.dialTimeout)
	if err != nil {
		p.logf("hsproxy: dial headscale at %s: %v", p.upstreamAddr, err)
		return
	}
	defer upstream.Close()

	relay(reader, tlsConn, upstream)
}

// Reports whether the session opens with a key request, without consuming
// anything: whatever is peeked stays in reader and is spliced to headscale if
// the session turns out to be control traffic.
//
// Waits for a full request line rather than a fixed byte count, because short
// requests exist and a client waiting on a reply would otherwise stall until
// the deadline.
func peekKeyRequest(reader *bufio.Reader) (bool, error) {
	for {
		want := reader.Buffered() + 1
		if want > maxRequestLineBytes {
			return false, nil
		}
		peeked, err := reader.Peek(want)
		if err != nil {
			if len(peeked) > 0 && errors.Is(err, io.EOF) {
				return false, nil
			}
			return false, err
		}
		peeked, _ = reader.Peek(reader.Buffered())
		if bytes.IndexByte(peeked, '\n') >= 0 {
			return bytes.HasPrefix(peeked, preauthKeyRequestLine), nil
		}
	}
}

// Answers a key request on the device's own session and closes it.
//
// Bootstrap sessions are refused even though their control traffic is
// allowed: the exemption exists so the first device can register with the key
// it got from the loopback-only CA page, and extending it to minting would let
// anyone who reached the tunnel during that window enroll themselves.
func (p *Proxy) serveKeyRequest(conn net.Conn, reader *bufio.Reader, username string, bootstrap bool) {
	request, err := http.ReadRequest(reader)
	if err != nil {
		p.logf("hsproxy: parse key request: %v", err)
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(request.Body, maxRequestLineBytes))
	_ = request.Body.Close()

	switch {
	case bootstrap:
		p.logf("hsproxy: refused a key to a bootstrap client; the first device's key comes from the CA page")
		writeResponse(conn, http.StatusForbidden, "text/plain; charset=utf-8",
			[]byte("Pre-auth keys are only issued to devices in pubkeys/\n"))
		return
	case p.minter == nil:
		writeResponse(conn, http.StatusNotFound, "text/plain; charset=utf-8",
			[]byte("Pre-auth keys are not issued by this deployment\n"))
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), mintTimeout)
	defer cancel()
	key, err := p.minter.MintPreauthKey(ctx, tailnet.DeviceTag, tailnet.PreauthKeyTTL)
	if err != nil {
		// Logged but not returned: the detail names internal hosts and
		// headscale state a device has no business learning.
		p.logf("hsproxy: mint a key for %q: %v", username, err)
		writeResponse(conn, http.StatusBadGateway, "text/plain; charset=utf-8",
			[]byte("Could not mint a pre-auth key\n"))
		return
	}

	body, err := json.Marshal(struct {
		PreauthKey string `json:"preauth_key"`
	}{key})
	if err != nil {
		p.logf("hsproxy: encode key response: %v", err)
		return
	}
	p.logf("hsproxy: issued a pre-auth key to %q", username)
	writeResponse(conn, http.StatusOK, "application/json", body)
}

// Writes a complete response that closes the connection, so the client never
// mistakes the session for one it can reuse for control traffic.
func writeResponse(conn net.Conn, status int, contentType string, body []byte) {
	response := &http.Response{
		StatusCode:    status,
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": {contentType}},
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Close:         true,
	}
	_ = response.Write(conn)
}

// Copies bytes in both directions until either side finishes, then tears both
// down. Closing both ends on the first completed direction is what stops a
// half-open session from lingering after headscale or the device goes away.
//
// The device side is read through clientReader so bytes already buffered while
// peeking the request line go upstream first.
func relay(clientReader io.Reader, client net.Conn, upstream net.Conn) {
	done := make(chan struct{}, 2)

	go func() {
		_, _ = io.Copy(upstream, clientReader)
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
