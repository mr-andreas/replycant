package tailnet

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Answers WhoIs from a fixed table and counts lookups, standing in for the
// tsnet node so the binder's caching can be tested without a tailnet.
type fakeWhoIs struct {
	mu      sync.Mutex
	byIP    map[string]string
	err     error
	lookups int
}

func (f *fakeWhoIs) whoIs(_ context.Context, remoteAddr string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lookups++
	if f.err != nil {
		return "", f.err
	}
	for ip, machineKey := range f.byIP {
		if len(remoteAddr) > len(ip) && remoteAddr[:len(ip)+1] == ip+":" {
			return machineKey, nil
		}
	}
	return "", errors.New("no such peer")
}

type recordedBinding struct{ machineKey, fingerprint string }

type bindingRecorder struct {
	mu    sync.Mutex
	binds []recordedBinding
}

func (r *bindingRecorder) bind(machineKey, fingerprint string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.binds = append(r.binds, recordedBinding{machineKey, fingerprint})
	return nil
}

func newTestBinder(whoIs *fakeWhoIs, recorder *bindingRecorder, clock *time.Time) *NodeBinder {
	binder := NewNodeBinder(whoIs.whoIs, recorder.bind, func(string, ...any) {})
	binder.now = func() time.Time { return *clock }
	return binder
}

// Every request reaching gitd identifies its node, so the binding is what lets
// revocation spare authorized devices. The node is looked up from the peer
// address and recorded against the key the request authenticated with.
func TestBinderRecordsTheCallersMachineKey(t *testing.T) {
	whoIs := &fakeWhoIs{byIP: map[string]string{"100.64.0.7": "mkey:phone"}}
	recorder := &bindingRecorder{}
	clock := time.Unix(0, 0)
	binder := newTestBinder(whoIs, recorder, &clock)

	binder.BindNode(context.Background(), "100.64.0.7:41234", "SHA256:phone")

	if len(recorder.binds) != 1 || recorder.binds[0] != (recordedBinding{"mkey:phone", "SHA256:phone"}) {
		t.Fatalf("expected the phone's node to be bound to its key, got %+v", recorder.binds)
	}
}

// A sync issues many LFS requests from the same node with the same key. Each
// lookup is a local API round trip, so a pair already seen recently is not
// looked up again, whatever source port the connection used.
func TestBinderSkipsPairsSeenRecently(t *testing.T) {
	whoIs := &fakeWhoIs{byIP: map[string]string{"100.64.0.7": "mkey:phone"}}
	recorder := &bindingRecorder{}
	clock := time.Unix(0, 0)
	binder := newTestBinder(whoIs, recorder, &clock)

	binder.BindNode(context.Background(), "100.64.0.7:41234", "SHA256:phone")
	binder.BindNode(context.Background(), "100.64.0.7:41999", "SHA256:phone")

	if whoIs.lookups != 1 {
		t.Errorf("a repeated pair must not be looked up again, got %d lookups", whoIs.lookups)
	}
}

// The cache only saves lookups; it must never hide a change. A different key
// from the same address is looked up, and so is a known pair once it is old,
// because a node that was expired and logged back in may now hold a different
// address, and an address may be reassigned to another node.
func TestBinderLooksUpAgainForANewKeyOrAfterTheCacheExpires(t *testing.T) {
	whoIs := &fakeWhoIs{byIP: map[string]string{"100.64.0.7": "mkey:phone"}}
	recorder := &bindingRecorder{}
	clock := time.Unix(0, 0)
	binder := newTestBinder(whoIs, recorder, &clock)

	binder.BindNode(context.Background(), "100.64.0.7:1", "SHA256:phone")
	binder.BindNode(context.Background(), "100.64.0.7:2", "SHA256:recovery")
	if whoIs.lookups != 2 {
		t.Fatalf("a new key from a known address must be looked up, got %d lookups", whoIs.lookups)
	}

	clock = clock.Add(bindingCacheTTL + time.Second)
	binder.BindNode(context.Background(), "100.64.0.7:3", "SHA256:phone")
	if whoIs.lookups != 3 {
		t.Errorf("a pair older than the cache lifetime must be looked up again, got %d lookups", whoIs.lookups)
	}
}

// A failed lookup leaves the node unbound, which at worst costs it one
// re-enrollment. It must not be cached, so the next request tries again.
func TestBinderRetriesAfterAFailedLookup(t *testing.T) {
	whoIs := &fakeWhoIs{err: errors.New("local API unavailable")}
	recorder := &bindingRecorder{}
	clock := time.Unix(0, 0)
	binder := newTestBinder(whoIs, recorder, &clock)

	binder.BindNode(context.Background(), "100.64.0.7:1", "SHA256:phone")
	if len(recorder.binds) != 0 {
		t.Fatalf("nothing can be bound without a machine key, got %+v", recorder.binds)
	}

	whoIs.mu.Lock()
	whoIs.err = nil
	whoIs.byIP = map[string]string{"100.64.0.7": "mkey:phone"}
	whoIs.mu.Unlock()
	binder.BindNode(context.Background(), "100.64.0.7:2", "SHA256:phone")
	if len(recorder.binds) != 1 {
		t.Errorf("the next request must retry the lookup and bind, got %+v", recorder.binds)
	}
}
