// Package tcprelay splices every connection on a listener to one fixed
// upstream address.
//
// It exists so gitd can offer the headscale control plane a second way in: one
// that runs inside the tailnet instead of through the hosted relay. A device
// that is already a tailnet member dials gitd's tailnet address, and gitd hands
// the bytes to hsproxy, which is the same mTLS front door the hosted relay
// leads to. The device's TLS session terminates at hsproxy either way, so this
// relay never sees plaintext and needs no knowledge of what it carries.
//
// Reusing gitd's existing tsnet node rather than giving hsproxy one of its own
// is deliberate: a second node would need its own pre-auth key, its own
// persistent state directory, and would show up as an extra machine in the
// user's tailnet, all to move bytes between two containers on the same
// compose network.
package tcprelay

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/netsplice"
)

// Bounds the upstream dial so a wedged hsproxy surfaces as a closed client
// connection rather than a goroutine and socket held indefinitely. The client
// retries, so failing promptly is the better behaviour.
const defaultDialTimeout = 10 * time.Second

// Where to send accepted connections.
type Config struct {
	// host:port of the service to splice to. Required.
	UpstreamAddr string

	DialTimeout time.Duration

	// Optional. Defaults to the standard logger.
	Logf func(format string, args ...any)
}

// Accepts connections until the listener is closed, splicing each one to the
// configured upstream.
//
// Returns the accept error, which on normal shutdown is net.ErrClosed because
// the caller closed the listener. Per-connection failures are logged and
// dropped rather than returned: one unreachable upstream must not stop the
// listener from serving the next device.
func Serve(listener net.Listener, config Config) error {
	upstreamAddr := strings.TrimSpace(config.UpstreamAddr)
	if upstreamAddr == "" {
		return errors.New("tcprelay: upstream address is required")
	}
	if _, _, err := net.SplitHostPort(upstreamAddr); err != nil {
		return fmt.Errorf("tcprelay: upstream address must be host:port, got %q: %w",
			upstreamAddr, err)
	}

	dialTimeout := config.DialTimeout
	if dialTimeout <= 0 {
		dialTimeout = defaultDialTimeout
	}
	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go handle(conn, upstreamAddr, dialTimeout, logf)
	}
}

func handle(client net.Conn, upstreamAddr string, dialTimeout time.Duration, logf func(string, ...any)) {
	defer client.Close()

	upstream, err := net.DialTimeout("tcp", upstreamAddr, dialTimeout)
	if err != nil {
		logf("tcprelay: dial %s for %s: %v", upstreamAddr, client.RemoteAddr(), err)
		return
	}
	defer upstream.Close()

	netsplice.Splice(context.Background(), client, upstream, netsplice.Options{})
}
