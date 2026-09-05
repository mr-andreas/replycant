// Package tunnelagent maintains the outbound connection that makes a home
// headscale reachable from the internet.
//
// The user's router is the problem this solves. Asking someone to forward a
// port is both a support burden and a security decision they are not equipped
// to make, and on CGNAT connections it is not possible at all. Instead the home
// side dials out to the hosted relay and holds that connection open; the relay
// then pushes each arriving device connection back down it as a new stream.
//
// The agent presents [hsproxy leaf, replycant CA] when it registers. The relay
// derives the subdomain from the CA it presents, so the agent never asks for a
// hostname and there is nothing for the two sides to disagree about.
//
// Nothing sensitive passes through the agent in readable form: it splices bytes
// between the relay and hsproxy, and the device's TLS session terminates at
// hsproxy's certificate.
package tunnelagent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"os"
	"strings"
	"time"

	"github.com/hashicorp/yamux"
)

const (
	defaultDialTimeout   = 30 * time.Second
	defaultKeepAlive     = 30 * time.Second
	defaultMinBackoff    = time.Second
	defaultMaxBackoff    = 2 * time.Minute
	defaultUpstreamDelay = 10 * time.Second
)

// Configures an agent.
type Config struct {
	// Relay registration endpoint, as host:port.
	RelayAddr string

	// Local hsproxy address that relayed streams are spliced to.
	UpstreamAddr string

	// The certificate and key hsproxy serves. Presenting the same leaf here is
	// what ties the registration to the deployment whose CA signed it.
	CertPath string
	KeyPath  string

	// The deployment CA. It is appended to the presented chain so the relay can
	// derive the label, and it is not used to verify the relay.
	CAPath string

	// Pins the relay's own certificate. Empty falls back to the system roots,
	// which is the normal case for a public AWS endpoint.
	RelayCAPath string

	// Overrides the SNI presented to the relay. Empty derives it from
	// RelayAddr.
	RelayServerName string

	DialTimeout time.Duration
	MinBackoff  time.Duration
	MaxBackoff  time.Duration

	Logf func(format string, args ...any)
}

// Fills in defaults and rejects configurations that cannot work, so a
// deployment mistake surfaces at startup rather than as a silent reconnect loop.
func (c *Config) normalize() error {
	if strings.TrimSpace(c.RelayAddr) == "" {
		return errors.New("tunnelagent: relay address is required")
	}
	if strings.Contains(c.RelayAddr, "://") {
		return fmt.Errorf("tunnelagent: relay address must be host:port, not a URL: %q", c.RelayAddr)
	}
	if strings.TrimSpace(c.UpstreamAddr) == "" {
		return errors.New("tunnelagent: upstream address is required")
	}
	if c.CertPath == "" || c.KeyPath == "" {
		return errors.New("tunnelagent: certificate and key are required")
	}
	if c.CAPath == "" {
		return errors.New("tunnelagent: CA certificate is required to derive the tunnel label")
	}

	if c.DialTimeout <= 0 {
		c.DialTimeout = defaultDialTimeout
	}
	if c.MinBackoff <= 0 {
		c.MinBackoff = defaultMinBackoff
	}
	if c.MaxBackoff <= 0 {
		c.MaxBackoff = defaultMaxBackoff
	}
	if c.Logf == nil {
		c.Logf = log.Printf
	}
	if c.RelayServerName == "" {
		host, _, err := net.SplitHostPort(c.RelayAddr)
		if err != nil {
			return fmt.Errorf("tunnelagent: relay address must be host:port: %w", err)
		}
		c.RelayServerName = host
	}
	return nil
}

// Holds the credential material and dial parameters for one agent.
type Agent struct {
	config    Config
	tlsConfig *tls.Config
}

// Loads credentials and prepares the TLS parameters used for every
// registration attempt.
func New(config Config) (*Agent, error) {
	if err := config.normalize(); err != nil {
		return nil, err
	}

	leafPair, err := tls.LoadX509KeyPair(config.CertPath, config.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("load hsproxy certificate: %w", err)
	}

	caPEM, err := os.ReadFile(config.CAPath)
	if err != nil {
		return nil, fmt.Errorf("read CA certificate: %w", err)
	}
	caDER, err := firstCertificateDER(caPEM)
	if err != nil {
		return nil, err
	}

	// The CA is appended so the relay receives [leaf, CA] and can both verify
	// the signature and derive the label. tls.LoadX509KeyPair only loads what
	// is in the certificate file, which for this deployment is the leaf alone.
	if len(leafPair.Certificate) == 1 {
		leafPair.Certificate = append(leafPair.Certificate, caDER)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{leafPair},
		ServerName:   config.RelayServerName,
		MinVersion:   tls.VersionTLS12,
	}
	if config.RelayCAPath != "" {
		relayCAPEM, err := os.ReadFile(config.RelayCAPath)
		if err != nil {
			return nil, fmt.Errorf("read relay CA certificate: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(relayCAPEM) {
			return nil, fmt.Errorf("no certificates found in relay CA file %q", config.RelayCAPath)
		}
		tlsConfig.RootCAs = pool
	}

	return &Agent{config: config, tlsConfig: tlsConfig}, nil
}

// Keeps a registration up until the context is cancelled.
//
// Reconnecting forever with backoff is the whole job: a home connection drops
// on every ISP hiccup, router reboot, and address change, and a device trying
// to pair during that window would otherwise see the deployment as gone.
func (a *Agent) Run(ctx context.Context) error {
	backoff := a.config.MinBackoff

	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		start := time.Now()
		err := a.serveOnce(ctx)
		switch {
		case ctx.Err() != nil:
			return ctx.Err()
		case err != nil:
			a.config.Logf("tunnel-agent: registration ended after %s: %v", time.Since(start).Round(time.Second), err)
		default:
			a.config.Logf("tunnel-agent: registration ended after %s", time.Since(start).Round(time.Second))
		}

		// A session that lasted a while indicates a healthy endpoint, so start
		// over from the short delay instead of inheriting a long backoff from
		// an outage that has since resolved.
		if time.Since(start) > defaultUpstreamDelay {
			backoff = a.config.MinBackoff
		}

		wait := jitter(backoff)
		a.config.Logf("tunnel-agent: reconnecting in %s", wait.Round(time.Millisecond))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}

		backoff *= 2
		if backoff > a.config.MaxBackoff {
			backoff = a.config.MaxBackoff
		}
	}
}

// Registers once and serves relayed streams until the session ends.
func (a *Agent) serveOnce(ctx context.Context) error {
	dialer := &net.Dialer{Timeout: a.config.DialTimeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", a.config.RelayAddr)
	if err != nil {
		return fmt.Errorf("dial relay %s: %w", a.config.RelayAddr, err)
	}

	tlsConn := tls.Client(rawConn, a.tlsConfig)
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = rawConn.Close()
		return fmt.Errorf("relay handshake: %w", err)
	}
	a.config.Logf("tunnel-agent: registered with relay %s", a.config.RelayAddr)

	// The relay opens streams towards this process, so the agent is the yamux
	// server. That inversion is what removes the need for an inbound port.
	muxConfig := yamux.DefaultConfig()
	muxConfig.KeepAliveInterval = defaultKeepAlive
	muxConfig.LogOutput = io.Discard

	session, err := yamux.Server(tlsConn, muxConfig)
	if err != nil {
		_ = rawConn.Close()
		return fmt.Errorf("start relay session: %w", err)
	}
	defer session.Close()

	// Closing the session on cancellation unblocks the Accept loop below.
	go func() {
		<-ctx.Done()
		_ = session.Close()
	}()

	for {
		stream, err := session.Accept()
		if err != nil {
			return fmt.Errorf("accept relayed stream: %w", err)
		}
		go a.handleStream(stream)
	}
}

// Splices one relayed device connection to the local hsproxy.
//
// No inspection happens here: the bytes are a TLS session between the device
// and hsproxy, and this process holds no key for it.
func (a *Agent) handleStream(stream net.Conn) {
	defer stream.Close()

	upstream, err := net.DialTimeout("tcp", a.config.UpstreamAddr, a.config.DialTimeout)
	if err != nil {
		a.config.Logf("tunnel-agent: dial hsproxy at %s: %v", a.config.UpstreamAddr, err)
		return
	}
	defer upstream.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, stream)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(stream, upstream)
		done <- struct{}{}
	}()
	<-done
}

// Spreads reconnect attempts so a relay restart does not bring every
// deployment back in the same instant.
func jitter(base time.Duration) time.Duration {
	if base <= 0 {
		return 0
	}
	return base/2 + time.Duration(rand.Int63n(int64(base/2)+1))
}
