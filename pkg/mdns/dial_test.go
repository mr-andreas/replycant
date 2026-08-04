package mdns

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestDialContextBypassesMDNSForNonLocalHosts verifies public DNS hosts keep standard dialing behavior.
func TestDialContextBypassesMDNSForNonLocalHosts(t *testing.T) {
	restore := setDialHooksForTest(
		func(context.Context, string) ([]net.IPAddr, error) {
			t.Fatalf("system resolver should not be used for non-.local host")
			return nil, nil
		},
		func(context.Context, string) ([]netip.Addr, error) {
			t.Fatalf("mdns resolver should not be used for non-.local host")
			return nil, nil
		},
		func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("dialed-directly")
		},
	)
	defer restore()

	_, err := DialContext(context.Background(), "tcp", "example.com:8443")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "dialed-directly")
}

// TestDialContextBypassesMDNSForLiteralIP ensures pre-resolved IP destinations never trigger host lookups.
func TestDialContextBypassesMDNSForLiteralIP(t *testing.T) {
	restore := setDialHooksForTest(
		func(context.Context, string) ([]net.IPAddr, error) {
			t.Fatalf("system resolver should not run for literal IP")
			return nil, nil
		},
		func(context.Context, string) ([]netip.Addr, error) {
			t.Fatalf("mdns resolver should not run for literal IP")
			return nil, nil
		},
		func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("literal-ip-dial")
		},
	)
	defer restore()

	_, err := DialContext(context.Background(), "tcp", "127.0.0.1:8443")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "literal-ip-dial")
}

// TestDialContextShortCircuitsWhenSystemResolverWorks keeps existing resolution behavior when OS DNS succeeds.
func TestDialContextShortCircuitsWhenSystemResolverWorks(t *testing.T) {
	mdnsCalls := 0
	var dialAddr string
	restore := setDialHooksForTest(
		func(context.Context, string) ([]net.IPAddr, error) {
			return []net.IPAddr{{IP: net.ParseIP("192.168.0.22")}}, nil
		},
		func(context.Context, string) ([]netip.Addr, error) {
			mdnsCalls++
			return nil, errors.New("should-not-be-called")
		},
		func(_ context.Context, _, addr string) (net.Conn, error) {
			dialAddr = addr
			return nil, errors.New("dial-attempted")
		},
	)
	defer restore()

	_, err := DialContext(context.Background(), "tcp", "replycant.local:8443")
	require.Error(t, err)
	assert.Equal(t, "192.168.0.22:8443", dialAddr)
	assert.Equal(t, 0, mdnsCalls)
}

// TestDialContextFallsBackToMDNS ensures .local hosts stay reachable when DNS stubs fail.
func TestDialContextFallsBackToMDNS(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	defer listener.Close()

	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			_ = conn.Close()
		}
	}()

	restore := setDialHooksForTest(
		func(context.Context, string) ([]net.IPAddr, error) {
			return nil, errors.New("dns-servfail")
		},
		func(context.Context, string) ([]netip.Addr, error) {
			return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
		},
		realDialContext,
	)
	defer restore()

	conn, err := DialContext(context.Background(), "tcp", "replycant.local:"+portOf(t, listener.Addr().String()))
	require.NoError(t, err)
	require.NotNil(t, conn)
	_ = conn.Close()
	<-acceptDone
}

// TestDialContextReturnsBothErrors preserves enough context to debug resolution failures.
func TestDialContextReturnsBothErrors(t *testing.T) {
	restore := setDialHooksForTest(
		func(context.Context, string) ([]net.IPAddr, error) {
			return nil, errors.New("system-resolver-failed")
		},
		func(context.Context, string) ([]netip.Addr, error) {
			return nil, errors.New("mdns-failed")
		},
		realDialContext,
	)
	defer restore()

	_, err := DialContext(context.Background(), "tcp", "replycant.local:8443")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "replycant.local")
	assert.Contains(t, err.Error(), "system-resolver-failed")
	assert.Contains(t, err.Error(), "mdns-failed")
}

func setDialHooksForTest(
	system func(context.Context, string) ([]net.IPAddr, error),
	mdns func(context.Context, string) ([]netip.Addr, error),
	dial func(context.Context, string, string) (net.Conn, error),
) func() {
	previousSystem := systemLookupIP
	previousMDNS := lookupMDNS
	previousDial := dialContext
	systemLookupIP = system
	lookupMDNS = mdns
	dialContext = dial
	return func() {
		systemLookupIP = previousSystem
		lookupMDNS = previousMDNS
		dialContext = previousDial
	}
}

func portOf(t *testing.T, addr string) string {
	t.Helper()
	_, port, err := net.SplitHostPort(addr)
	require.NoError(t, err)
	return port
}
