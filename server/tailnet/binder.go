package tailnet

import (
	"context"
	"net"
	"sync"
	"time"
)

// How long a (peer address, key) pair is trusted to still mean the same
// node. Short enough that a node that logged in again, or an address
// headscale handed to another node, is noticed well before it matters.
const bindingCacheTTL = 5 * time.Minute

// Resolves a tailnet peer address to the machine key of the node behind it.
type WhoIsFunc func(ctx context.Context, remoteAddr string) (machineKey string, err error)

// Turns gitd's authenticated requests into node bindings for the Reconciler.
//
// gitd serves many requests per sync, and resolving a peer is a round trip to
// the local tsnet API, so recently seen pairs are skipped. Failures are logged
// rather than returned: an unbound node is expired at the next revocation and
// re-enrolls, which is never worth refusing a request over.
type NodeBinder struct {
	whoIs WhoIsFunc
	bind  func(machineKey, fingerprint string) error
	logf  func(format string, args ...any)
	now   func() time.Time

	mu   sync.Mutex
	seen map[string]time.Time
}

func NewNodeBinder(whoIs WhoIsFunc, bind func(machineKey, fingerprint string) error, logf func(format string, args ...any)) *NodeBinder {
	return &NodeBinder{
		whoIs: whoIs,
		bind:  bind,
		logf:  logf,
		now:   time.Now,
		seen:  map[string]time.Time{},
	}
}

// Binds the node at remoteAddr to fingerprint. Implements gitd.NodeBinder.
func (b *NodeBinder) BindNode(ctx context.Context, remoteAddr, fingerprint string) {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	cacheKey := host + " " + fingerprint
	now := b.now()

	b.mu.Lock()
	if seenAt, ok := b.seen[cacheKey]; ok && now.Sub(seenAt) < bindingCacheTTL {
		b.mu.Unlock()
		return
	}
	b.mu.Unlock()

	machineKey, err := b.whoIs(ctx, remoteAddr)
	if err != nil {
		b.logf("tailnet: cannot identify the node at %s: %v", remoteAddr, err)
		return
	}
	if err := b.bind(machineKey, fingerprint); err != nil {
		b.logf("tailnet: bind node %s to %s: %v", machineKey, fingerprint, err)
		return
	}

	b.mu.Lock()
	b.seen[cacheKey] = now
	for key, seenAt := range b.seen {
		if now.Sub(seenAt) >= bindingCacheTTL {
			delete(b.seen, key)
		}
	}
	b.mu.Unlock()
}
