package netsplice

import (
	"bufio"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

// Returns once Splice does, failing the test if it never does: a splice that
// outlives both of its connections is a leaked goroutine per session.
func runSplice(t *testing.T, ctx context.Context, a, b net.Conn, options Options) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})
	go func() {
		Splice(ctx, a, b, options)
		close(done)
	}()
	return done
}

func waitDone(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Splice did not return")
	}
}

func readN(t *testing.T, conn net.Conn, n int) string {
	t.Helper()
	buf := make([]byte, n)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(buf)
}

// Every relay in the stack carries a TLS session it cannot read, so bytes
// must pass through unchanged in both directions.
func TestSpliceCopiesBothWays(t *testing.T) {
	a, aPeer := net.Pipe()
	b, bPeer := net.Pipe()
	done := runSplice(t, context.Background(), a, b, Options{})

	go func() { _, _ = aPeer.Write([]byte("hello")) }()
	if got := readN(t, bPeer, 5); got != "hello" {
		t.Errorf("a to b carried %q", got)
	}
	go func() { _, _ = bPeer.Write([]byte("world")) }()
	if got := readN(t, aPeer, 5); got != "world" {
		t.Errorf("b to a carried %q", got)
	}

	_ = aPeer.Close()
	waitDone(t, done)
}

// When one side goes away the other must be torn down too, or a device that
// vanished leaves its upstream session open until the server times it out.
func TestSpliceClosesBothSidesWhenEitherEnds(t *testing.T) {
	a, aPeer := net.Pipe()
	b, bPeer := net.Pipe()
	done := runSplice(t, context.Background(), a, b, Options{})

	_ = bPeer.Close()
	waitDone(t, done)

	_ = aPeer.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := aPeer.Read(make([]byte, 1)); err != io.EOF {
		t.Errorf("the surviving side must see the session end, got %v", err)
	}
}

// hsproxy peeks the request line to route plain requests, so some of the
// device's bytes already sit in a buffer. They must go upstream first, or the
// TLS session it relays is corrupted.
func TestSpliceForwardsBufferedBytesFirst(t *testing.T) {
	a, aPeer := net.Pipe()
	b, bPeer := net.Pipe()
	reader := bufio.NewReader(a)
	go func() { _, _ = aPeer.Write([]byte("peeked-rest")) }()
	if _, err := reader.Peek(6); err != nil {
		t.Fatalf("peek: %v", err)
	}
	done := runSplice(t, context.Background(), a, b, Options{AReader: reader})

	if got := readN(t, bPeer, len("peeked-rest")); got != "peeked-rest" {
		t.Errorf("upstream received %q", got)
	}

	_ = aPeer.Close()
	waitDone(t, done)
}

// The loopback shim relays for a client that may be shutting down. Ending
// its context must end the session even while both sides are idle.
func TestSpliceEndsWithTheContext(t *testing.T) {
	a, _ := net.Pipe()
	b, _ := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	done := runSplice(t, ctx, a, b, Options{})

	cancel()
	waitDone(t, done)
}
