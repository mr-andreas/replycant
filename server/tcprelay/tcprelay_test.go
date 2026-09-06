package tcprelay_test

import (
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/server/tcprelay"
)

// Stands up an upstream that echoes whatever it is sent, so a test can prove
// bytes made the whole round trip rather than merely that a dial succeeded.
func startEchoUpstream(t *testing.T) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the echo upstream: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	return listener.Addr().String()
}

// Starts a relay on a fresh loopback listener and returns its address.
func startRelay(t *testing.T, config tcprelay.Config) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the relay: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		_ = tcprelay.Serve(listener, config)
	}()
	return listener.Addr().String()
}

// The relay exists to carry a TLS session it cannot read, so the only thing
// that matters is that bytes arrive unmodified in both directions.
func TestRelayCarriesBytesBothWays(t *testing.T) {
	upstream := startEchoUpstream(t)
	addr := startRelay(t, tcprelay.Config{UpstreamAddr: upstream, Logf: func(string, ...any) {}})

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial the relay: %v", err)
	}
	defer conn.Close()

	payload := []byte("tailscale-control-protocol")
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write through the relay: %v", err)
	}

	received := make([]byte, len(payload))
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	if _, err := io.ReadFull(conn, received); err != nil {
		t.Fatalf("read the echoed bytes back: %v", err)
	}
	if string(received) != string(payload) {
		t.Errorf("relay altered the stream: sent %q, got %q", payload, received)
	}
}

// The control protocol holds one stream open for the life of a session, so a
// relay that only survived a single request/response exchange would break the
// map poll as soon as it went quiet.
func TestRelayKeepsTheStreamOpenAcrossExchanges(t *testing.T) {
	upstream := startEchoUpstream(t)
	addr := startRelay(t, tcprelay.Config{UpstreamAddr: upstream, Logf: func(string, ...any) {}})

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial the relay: %v", err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	for round := 0; round < 3; round++ {
		payload := []byte(fmt.Sprintf("round-%d", round))
		if _, err := conn.Write(payload); err != nil {
			t.Fatalf("round %d write: %v", round, err)
		}
		received := make([]byte, len(payload))
		if _, err := io.ReadFull(conn, received); err != nil {
			t.Fatalf("round %d read: %v", round, err)
		}
		if string(received) != string(payload) {
			t.Fatalf("round %d altered the stream: got %q", round, received)
		}
	}
}

// A dead upstream must fail only the connection that hit it. Taking down the
// whole listener would mean one restart of headscale permanently stopped the
// server from carrying control traffic until gitd itself restarted.
func TestUnreachableUpstreamDoesNotStopTheRelay(t *testing.T) {
	// Bind and immediately release a port so the address is well-formed but
	// nothing is listening on it.
	dead, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve an address: %v", err)
	}
	deadAddr := dead.Addr().String()
	_ = dead.Close()

	var logged sync.WaitGroup
	logged.Add(1)
	var once sync.Once
	addr := startRelay(t, tcprelay.Config{
		UpstreamAddr: deadAddr,
		DialTimeout:  time.Second,
		Logf:         func(string, ...any) { once.Do(logged.Done) },
	})

	first, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial the relay: %v", err)
	}
	// The relay closes the client side when it cannot reach the upstream,
	// which is what turns the failure into a prompt error rather than a hang.
	if err := first.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	if _, err := first.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Errorf("expected the relay to close the connection, got %v", err)
	}
	_ = first.Close()
	logged.Wait()

	// The listener must still be accepting.
	second, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("the relay must still accept connections after a failed dial: %v", err)
	}
	_ = second.Close()
}

// gitd closes the tailnet node on shutdown, which closes this listener. Serve
// has to return then rather than spinning on a closed listener.
func TestServeReturnsWhenTheListenerCloses(t *testing.T) {
	upstream := startEchoUpstream(t)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- tcprelay.Serve(listener, tcprelay.Config{
			UpstreamAddr: upstream,
			Logf:         func(string, ...any) {},
		})
	}()

	_ = listener.Close()
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, net.ErrClosed) {
			t.Errorf("a closed listener is normal shutdown, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after the listener closed")
	}
}

// A missing upstream is a deployment mistake, and it must be reported where it
// can be fixed rather than as a per-connection failure much later.
func TestServeRejectsAnEmptyUpstream(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	if err := tcprelay.Serve(listener, tcprelay.Config{}); err == nil {
		t.Fatal("Serve must refuse a config with no upstream address")
	}
}
