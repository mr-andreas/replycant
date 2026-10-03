package tailnet

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"
)

// Stands in for headscale's node API so reconciliation can be tested as a
// decision about git state, independent of a running control plane.
type fakeNodeStore struct {
	mu        sync.Mutex
	nodes     []Node
	deleted   []string
	deleteErr error
	listErr   error
}

func (s *fakeNodeStore) ListNodes(context.Context) ([]Node, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.listErr != nil {
		return nil, s.listErr
	}
	return append([]Node(nil), s.nodes...), nil
}

func (s *fakeNodeStore) DeleteNode(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.deleteErr != nil {
		return s.deleteErr
	}
	s.deleted = append(s.deleted, id)
	remaining := s.nodes[:0]
	for _, node := range s.nodes {
		if node.ID != id {
			remaining = append(remaining, node)
		}
	}
	s.nodes = remaining
	return nil
}

func (s *fakeNodeStore) deletedIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := append([]string(nil), s.deleted...)
	sort.Strings(ids)
	return ids
}

// A tailnet as it looks in production: gitd's own node plus two devices.
func newHouseholdStore() *fakeNodeStore {
	return &fakeNodeStore{nodes: []Node{
		{ID: "1", Name: "gitd", Tags: []string{ServerTag}},
		{ID: "2", Name: "phone", Tags: []string{DeviceTag}},
		{ID: "3", Name: "laptop", Tags: []string{DeviceTag}},
	}}
}

// The authorized set as git reports it, swappable between reconciles to model
// pushes that add or remove keys.
type keySource struct {
	mu   sync.Mutex
	keys []string
	err  error
}

func (k *keySource) set(keys ...string) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.keys = keys
}

func (k *keySource) read() ([]string, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return append([]string(nil), k.keys...), k.err
}

func newTestReconciler(t *testing.T, store NodeStore, keys *keySource, markerPath string) *Reconciler {
	t.Helper()
	reconciler, err := NewReconciler(ReconcilerConfig{
		Nodes:          store,
		AuthorizedKeys: keys.read,
		MarkerPath:     markerPath,
		Logf:           t.Logf,
	})
	if err != nil {
		t.Fatalf("a complete config must build a reconciler: %v", err)
	}
	return reconciler
}

// Brings the reconciler to a known, already-reconciled state so a test can
// focus on what one subsequent push does.
func primedReconciler(t *testing.T, store *fakeNodeStore, keys *keySource) *Reconciler {
	t.Helper()
	reconciler := newTestReconciler(t, store, keys, filepath.Join(t.TempDir(), "reconciled-keys.json"))
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("priming reconcile: %v", err)
	}
	store.mu.Lock()
	store.deleted = nil
	store.nodes = newHouseholdStore().nodes
	store.mu.Unlock()
	return reconciler
}

// Removing a key from pubkeys/ is how a device is revoked. headscale cannot
// say which node belongs to which key, so every device node is deleted and the
// still-authorized devices re-enroll through hsproxy; the revoked one cannot.
// gitd's own node must survive, or no device could reach the server at all.
func TestRemovedKeyDeletesEveryDeviceNodeButNotTheServer(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:laptop")
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile after a revocation: %v", err)
	}

	if got := store.deletedIDs(); len(got) != 2 || got[0] != "2" || got[1] != "3" {
		t.Errorf("expected both device nodes to be deleted, got %v", got)
	}
}

// Pairing adds a key on every new device. Deleting nodes then would knock the
// whole household off the tailnet each time someone pairs a phone.
func TestAddedKeyDeletesNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:phone", "SHA256:laptop")
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile after a pairing: %v", err)
	}

	if got := store.deletedIDs(); len(got) != 0 {
		t.Errorf("adding a key must not delete any node, got %v", got)
	}
}

// Reconciling the same authorized set twice is what happens on every push that
// does not touch pubkeys/. It must be free of side effects.
func TestUnchangedKeysDeleteNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile with nothing changed: %v", err)
	}
	if got := store.deletedIDs(); len(got) != 0 {
		t.Errorf("an unchanged key set must not delete any node, got %v", got)
	}
}

// Without a marker gitd cannot know whether a key was removed while it was not
// watching, for instance in a crash between a push landing and reconciling it.
// Dropping device nodes once is the safe answer: authorized devices re-enroll
// on their own, so the cost is a brief reconnect rather than a missed
// revocation.
func TestMissingMarkerDropsDeviceNodesOnce(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	marker := filepath.Join(t.TempDir(), "reconciled-keys.json")
	reconciler := newTestReconciler(t, store, keys, marker)

	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	if got := store.deletedIDs(); len(got) != 2 {
		t.Fatalf("a missing marker must drop both device nodes, got %v", got)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the marker must be written after reconciling: %v", err)
	}

	store.mu.Lock()
	store.deleted = nil
	store.nodes = newHouseholdStore().nodes
	store.mu.Unlock()

	if err := newTestReconciler(t, store, keys, marker).Reconcile(context.Background()); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	if got := store.deletedIDs(); len(got) != 0 {
		t.Errorf("once the marker exists, a restart must not drop nodes again, got %v", got)
	}
}

// A marker that cannot be parsed is as uninformative as a missing one, and must
// be treated the same way rather than as an empty set that hides a removal.
func TestCorruptMarkerIsTreatedAsMissing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	marker := filepath.Join(t.TempDir(), "reconciled-keys.json")
	if err := os.WriteFile(marker, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write corrupt marker: %v", err)
	}

	if err := newTestReconciler(t, store, keys, marker).Reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile with a corrupt marker: %v", err)
	}
	if got := store.deletedIDs(); len(got) != 2 {
		t.Errorf("a corrupt marker must drop device nodes, got %v", got)
	}
}

// If headscale refuses a deletion, the revocation has not happened. The marker
// must keep the old set so the next reconcile sees the removal again and
// retries, instead of recording the revocation as done.
func TestFailedDeletionIsRetriedNextTime(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:laptop")
	store.mu.Lock()
	store.deleteErr = errors.New("headscale returned 503")
	store.mu.Unlock()
	if err := reconciler.Reconcile(context.Background()); err == nil {
		t.Fatal("a failed deletion must be reported")
	}

	store.mu.Lock()
	store.deleteErr = nil
	store.mu.Unlock()
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("retry after headscale recovers: %v", err)
	}
	if got := store.deletedIDs(); len(got) != 2 {
		t.Errorf("the retry must delete the device nodes, got %v", got)
	}
}

// If git cannot be read, nothing is known about who is authorized. Deleting
// nodes on that basis would disconnect the household for no reason.
func TestUnreadableKeysDeleteNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	reconciler := primedReconciler(t, store, keys)

	keys.mu.Lock()
	keys.err = errors.New("failed to open repository")
	keys.mu.Unlock()
	if err := reconciler.Reconcile(context.Background()); err == nil {
		t.Fatal("an unreadable key set must be reported")
	}
	if got := store.deletedIDs(); len(got) != 0 {
		t.Errorf("nothing may be deleted when git cannot be read, got %v", got)
	}
}

// gitd triggers a reconcile after every receive-pack, and pushes can arrive
// back to back. Triggers must never block the push handler, and a trigger
// made before the worker starts must still be acted on.
func TestTriggerIsNonBlockingAndEventuallyReconciles(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:laptop")
	for range 5 {
		reconciler.Trigger()
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go reconciler.Run(ctx)

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(store.deletedIDs()) == 2 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("a queued trigger must lead to a reconcile, deleted %v", store.deletedIDs())
}

// Every dependency is needed to decide anything, so an incomplete config is
// rejected when gitd starts rather than silently skipping revocation.
func TestNewReconcilerRejectsIncompleteConfig(t *testing.T) {
	keys := &keySource{}
	complete := ReconcilerConfig{
		Nodes:          newHouseholdStore(),
		AuthorizedKeys: keys.read,
		MarkerPath:     filepath.Join(t.TempDir(), "marker.json"),
	}
	for _, testCase := range []struct {
		name   string
		mutate func(*ReconcilerConfig)
	}{
		{"no node store", func(c *ReconcilerConfig) { c.Nodes = nil }},
		{"no key source", func(c *ReconcilerConfig) { c.AuthorizedKeys = nil }},
		{"no marker path", func(c *ReconcilerConfig) { c.MarkerPath = " " }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			config := complete
			testCase.mutate(&config)
			if _, err := NewReconciler(config); err == nil {
				t.Fatal("an incomplete config must be rejected")
			}
		})
	}
}
