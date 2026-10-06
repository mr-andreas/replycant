package tailnet

import (
	"context"
	"encoding/json"
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
	expired   []string
	expireErr error
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

func (s *fakeNodeStore) ExpireNode(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.expireErr != nil {
		return s.expireErr
	}
	s.expired = append(s.expired, id)
	return nil
}

func (s *fakeNodeStore) expiredIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := append([]string(nil), s.expired...)
	sort.Strings(ids)
	return ids
}

func (s *fakeNodeStore) resetExpired() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expired = nil
}

// A tailnet as it looks in production: gitd's own node plus two devices.
func newHouseholdStore() *fakeNodeStore {
	return &fakeNodeStore{nodes: []Node{
		{ID: "1", MachineKey: "mkey:gitd", Name: "gitd", Tags: []string{ServerTag}},
		{ID: "2", MachineKey: "mkey:phone", Name: "phone", Tags: []string{DeviceTag}},
		{ID: "3", MachineKey: "mkey:laptop", Name: "laptop", Tags: []string{DeviceTag}},
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
	reconciler := newTestReconciler(t, store, keys, filepath.Join(t.TempDir(), "reconcile-state.json"))
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("priming reconcile: %v", err)
	}
	store.mu.Lock()
	store.expired = nil
	store.nodes = newHouseholdStore().nodes
	store.mu.Unlock()
	return reconciler
}

func bind(t *testing.T, reconciler *Reconciler, machineKey, fingerprint string) {
	t.Helper()
	if err := reconciler.Bind(machineKey, fingerprint); err != nil {
		t.Fatalf("bind %s to %s: %v", machineKey, fingerprint, err)
	}
}

func reconcile(t *testing.T, reconciler *Reconciler) {
	t.Helper()
	if err := reconciler.Reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
}

func assertExpired(t *testing.T, store *fakeNodeStore, want ...string) {
	t.Helper()
	got := store.expiredIDs()
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("expected nodes %v to be expired, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("expected nodes %v to be expired, got %v", want, got)
		}
	}
}

// Removing a key from pubkeys/ is how a device is revoked. gitd has seen which
// node each device authenticates from, so only the revoked device's node is
// expired; the rest of the household keeps its connection. gitd's own node
// must survive, or no device could reach the server at all.
func TestRemovedKeyExpiresOnlyTheRevokedDevicesNode(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)
	bind(t, reconciler, "mkey:phone", "SHA256:phone")
	bind(t, reconciler, "mkey:laptop", "SHA256:laptop")

	keys.set("SHA256:laptop")
	reconcile(t, reconciler)

	assertExpired(t, store, "2")
}

// A node gitd has never seen authenticate could belong to anyone holding a
// key, including the device just revoked. When a revocation happens it is
// expired too; if it belongs to an authorized device, that device re-enrolls
// through hsproxy and is bound on its next request.
func TestRemovedKeyExpiresNodesGitdHasNotSeen(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)
	bind(t, reconciler, "mkey:laptop", "SHA256:laptop")

	keys.set("SHA256:laptop")
	reconcile(t, reconciler)

	assertExpired(t, store, "2")
}

// A key can come and go without gitd ever recording it, for instance when
// both pushes land while gitd is down. A node gitd saw authenticate with a
// key that is no longer authorized is still the revoked device's node.
func TestBoundNodeExpiresWhenItsKeyIsGoneEvenIfNeverRecorded(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	reconciler := primedReconciler(t, store, keys)
	bind(t, reconciler, "mkey:phone", "SHA256:phone")
	bind(t, reconciler, "mkey:laptop", "SHA256:laptop")

	reconcile(t, reconciler)

	assertExpired(t, store, "3")
}

// An expired node stays listed in headscale. Once its device is revoked,
// later pushes must not expire it again on every reconcile.
func TestRevokedNodeIsExpiredOnlyOnce(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)
	bind(t, reconciler, "mkey:phone", "SHA256:phone")
	bind(t, reconciler, "mkey:laptop", "SHA256:laptop")
	keys.set("SHA256:phone")
	reconcile(t, reconciler)
	store.resetExpired()

	reconcile(t, reconciler)

	assertExpired(t, store)
}

// Pairing adds a key on every new device. Expiring nodes then would knock the
// whole household off the tailnet each time someone pairs a phone.
func TestAddedKeyExpiresNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:phone", "SHA256:laptop")
	reconcile(t, reconciler)

	assertExpired(t, store)
}

// While the repository is empty, the CA page hands a join key to anyone who
// can open it, and hsproxy admits any certificate. A host that joined in that
// window was never authorized by pubkeys/, so the first push must take it off
// the tailnet. The device that made the push has just authenticated with the
// key it pushed, so it keeps its node and its first sync is not interrupted.
func TestFirstKeyDropsBootstrapJoinersButNotThePusher(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	reconciler := primedReconciler(t, store, keys)
	bind(t, reconciler, "mkey:phone", "SHA256:phone")
	bind(t, reconciler, "mkey:laptop", "SHA256:stranger")

	keys.set("SHA256:phone")
	reconcile(t, reconciler)

	assertExpired(t, store, "3")
}

// An empty repository is reconciled on every timer tick before the first push.
// Those runs must not keep expiring the node the first device is joining with.
func TestEmptyKeySetStaysEmptyExpiresNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	reconciler := primedReconciler(t, store, keys)

	reconcile(t, reconciler)

	assertExpired(t, store)
}

// Reconciling the same authorized set twice is what happens on every push that
// does not touch pubkeys/. It must be free of side effects, including for
// nodes gitd has not seen yet.
func TestUnchangedKeysExpireNothing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	reconcile(t, reconciler)

	assertExpired(t, store)
}

// Without a state file gitd cannot know whether a key was removed while it was
// not watching, for instance in a crash between a push landing and reconciling
// it. With no record of which node is whose either, dropping every device node
// once is the safe answer: authorized devices re-enroll on their own, so the
// cost is a brief reconnect rather than a missed revocation.
func TestMissingStateDropsDeviceNodesOnce(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	marker := filepath.Join(t.TempDir(), "reconcile-state.json")
	reconciler := newTestReconciler(t, store, keys, marker)

	reconcile(t, reconciler)
	assertExpired(t, store, "2", "3")
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the state must be written after reconciling: %v", err)
	}

	store.resetExpired()
	reconcile(t, newTestReconciler(t, store, keys, marker))
	assertExpired(t, store)
}

// A state file that cannot be parsed is as uninformative as a missing one, and
// must be treated the same way rather than as an empty set that hides a removal
// or as bindings that protect nodes they should not.
func TestCorruptStateIsTreatedAsMissing(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone")
	marker := filepath.Join(t.TempDir(), "reconcile-state.json")
	if err := os.WriteFile(marker, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write corrupt state: %v", err)
	}

	reconcile(t, newTestReconciler(t, store, keys, marker))

	assertExpired(t, store, "2", "3")
}

// gitd restarts on every deploy. Which node belongs to which key has to
// survive that, or the first revocation after a restart would log the whole
// household out again.
func TestBindingsSurviveARestart(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	marker := filepath.Join(t.TempDir(), "reconcile-state.json")
	first := newTestReconciler(t, store, keys, marker)
	reconcile(t, first)
	bind(t, first, "mkey:phone", "SHA256:phone")
	bind(t, first, "mkey:laptop", "SHA256:laptop")
	store.resetExpired()

	restarted := newTestReconciler(t, store, keys, marker)
	keys.set("SHA256:laptop")
	reconcile(t, restarted)

	assertExpired(t, store, "2")
}

// A node seen authenticating since startup proved it holds that key, whatever
// the state file said. Losing the file must not discard what gitd learned
// since, or a crash during a push would drop the pusher as well.
func TestBindingsMadeBeforeTheFirstReconcileAreHonoured(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := newTestReconciler(t, store, keys, filepath.Join(t.TempDir(), "reconcile-state.json"))
	bind(t, reconciler, "mkey:phone", "SHA256:phone")

	reconcile(t, reconciler)

	assertExpired(t, store, "3")
}

// headscale forgets nodes when its database is wiped. Bindings for machine
// keys it no longer lists are dropped so the state does not grow forever.
func TestBindingsForUnlistedNodesArePruned(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	marker := filepath.Join(t.TempDir(), "reconcile-state.json")
	reconciler := newTestReconciler(t, store, keys, marker)
	reconcile(t, reconciler)
	bind(t, reconciler, "mkey:phone", "SHA256:phone")
	bind(t, reconciler, "mkey:gone", "SHA256:laptop")

	keys.set("SHA256:phone")
	reconcile(t, reconciler)

	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	var state struct {
		Nodes map[string]string `json:"nodes"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("decode state: %v", err)
	}
	if _, ok := state.Nodes["mkey:gone"]; ok {
		t.Errorf("a binding for a node headscale no longer lists must be pruned, got %v", state.Nodes)
	}
	if state.Nodes["mkey:phone"] != "SHA256:phone" {
		t.Errorf("a binding for a listed node must be kept, got %v", state.Nodes)
	}
}

// A binding is only useful if it is valid. An empty machine key or fingerprint
// means gitd could not identify the peer, and must not be recorded.
func TestBindRejectsIncompleteBindings(t *testing.T) {
	keys := &keySource{}
	reconciler := newTestReconciler(t, newHouseholdStore(), keys, filepath.Join(t.TempDir(), "state.json"))
	if err := reconciler.Bind("", "SHA256:phone"); err == nil {
		t.Error("a binding without a machine key must be rejected")
	}
	if err := reconciler.Bind("mkey:phone", " "); err == nil {
		t.Error("a binding without a fingerprint must be rejected")
	}
}

// If headscale refuses to expire a node, the revocation has not happened. The
// state must keep the old set so the next reconcile sees the removal again
// and retries, instead of recording the revocation as done.
func TestFailedExpiryIsRetriedNextTime(t *testing.T) {
	store := newHouseholdStore()
	keys := &keySource{}
	keys.set("SHA256:phone", "SHA256:laptop")
	reconciler := primedReconciler(t, store, keys)

	keys.set("SHA256:laptop")
	store.mu.Lock()
	store.expireErr = errors.New("headscale returned 503")
	store.mu.Unlock()
	if err := reconciler.Reconcile(context.Background()); err == nil {
		t.Fatal("a failed expiry must be reported")
	}

	store.mu.Lock()
	store.expireErr = nil
	store.mu.Unlock()
	reconcile(t, reconciler)
	assertExpired(t, store, "2", "3")
}

// If git cannot be read, nothing is known about who is authorized. Expiring
// nodes on that basis would disconnect the household for no reason.
func TestUnreadableKeysExpireNothing(t *testing.T) {
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
	assertExpired(t, store)
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
		if len(store.expiredIDs()) == 2 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("a queued trigger must lead to a reconcile, expired %v", store.expiredIDs())
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
