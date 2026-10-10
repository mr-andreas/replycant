// Package netsplice joins two connections byte for byte.
//
// Every hop between a device and the control plane (the hosted relay, the
// tunnel agent, hsproxy, the loopback shim, the CLI agent's proxy) relays a
// session it cannot or must not parse. One implementation keeps them agreeing
// on when a session ends.
package netsplice

import (
	"context"
	"io"
	"net"
	"sync"
)

// Options adjusts a splice.
type Options struct {
	// Read in place of a, for callers that already buffered some of a's
	// bytes while deciding where to route it. Optional.
	AReader io.Reader
}

// Copies bytes between a and b until either direction finishes or ctx ends,
// then closes both and waits for both copies to stop.
//
// One direction finishing ends the session because the protocols carried
// here either finish together or hold the session open both ways; a peer
// left half-open would only linger until a server-side timeout.
func Splice(ctx context.Context, a, b net.Conn, options Options) {
	aReader := options.AReader
	if aReader == nil {
		aReader = a
	}

	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			_ = a.Close()
			_ = b.Close()
		})
	}
	stop := context.AfterFunc(ctx, closeBoth)
	defer stop()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(b, aReader)
		closeBoth()
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(a, b)
		closeBoth()
	}()
	wg.Wait()
}
