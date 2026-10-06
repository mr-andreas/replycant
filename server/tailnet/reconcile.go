package tailnet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// How often to re-check without a push. Covers a reconcile that failed because
// headscale was briefly down, so a revocation is not left waiting for the next
// unrelated push.
const defaultReconcileInterval = 5 * time.Minute

// Bounds one reconcile, so a wedged headscale cannot pin the worker.
const reconcileTimeout = 30 * time.Second

// The part of headscale's API revocation uses. An interface so reconciliation
// can be tested without a control plane; production uses Client.
type NodeStore interface {
	ListNodes(ctx context.Context) ([]Node, error)
	ExpireNode(ctx context.Context, id string) error
}

// Everything a reconciler needs to keep headscale in line with pubkeys/.
type ReconcilerConfig struct {
	Nodes NodeStore

	// Fingerprints of every key pubkeys/ on main authorizes right now. Read on
	// each reconcile, never cached, so a push is seen as soon as it lands.
	AuthorizedKeys func() ([]string, error)

	// Where the last reconciled key set and the node bindings are recorded.
	// It is only a cache: a missing or unreadable file costs one round of
	// device re-enrollment, never a missed revocation.
	MarkerPath string

	// Optional. Defaults to defaultReconcileInterval.
	Interval time.Duration

	// Optional. Defaults to the standard logger.
	Logf func(format string, args ...any)
}

// Expires device nodes in headscale when a key leaves pubkeys/, so revoking
// a device takes it off the tailnet immediately instead of only refusing its
// next control session.
//
// headscale cannot record which pubkey a node belongs to: tailnet hostnames
// are chosen by devices and tags are fixed by the policy file. gitd learns it
// instead, by binding each node's machine key to the key its requests
// authenticate with. When a revocation happens, every device node that is
// not bound to a key still in pubkeys/ is expired: the revoked device's, and
// any gitd has not seen yet. An authorized device among the latter asks
// hsproxy for a fresh key and comes straight back; the revoked one cannot.
// gitd's own tag:server node is never touched. See Client.ExpireNode for why
// nodes are expired rather than deleted.
type Reconciler struct {
	nodes          NodeStore
	authorizedKeys func() ([]string, error)
	markerPath     string
	interval       time.Duration
	logf           func(format string, args ...any)

	// Capacity one, so any number of triggers between two runs collapse into
	// a single reconcile and Trigger never blocks a push handler.
	pending chan struct{}

	// Guards the state below and its file, which request goroutines update
	// through Bind while the worker reconciles.
	mu sync.Mutex

	// The key set last reconciled, or nil when nothing is known about it.
	keys []string

	// Machine key to the fingerprint the node last authenticated with.
	bindings map[string]string
}

// Validates the configuration so a deployment that cannot revoke fails at
// startup rather than silently leaving revoked devices on the tailnet.
func NewReconciler(config ReconcilerConfig) (*Reconciler, error) {
	if config.Nodes == nil {
		return nil, errors.New("reconciler: a headscale node store is required")
	}
	if config.AuthorizedKeys == nil {
		return nil, errors.New("reconciler: a source of authorized keys is required")
	}
	markerPath := strings.TrimSpace(config.MarkerPath)
	if markerPath == "" {
		return nil, errors.New("reconciler: a marker path is required")
	}
	interval := config.Interval
	if interval <= 0 {
		interval = defaultReconcileInterval
	}
	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}
	reconciler := &Reconciler{
		nodes:          config.Nodes,
		authorizedKeys: config.AuthorizedKeys,
		markerPath:     markerPath,
		interval:       interval,
		logf:           logf,
		pending:        make(chan struct{}, 1),
	}
	reconciler.keys, reconciler.bindings = reconciler.readState()
	return reconciler, nil
}

// Asks for a reconcile soon. Called after every push; never blocks.
func (r *Reconciler) Trigger() {
	select {
	case r.pending <- struct{}{}:
	default:
	}
}

// Records that the node with machineKey just authenticated with the key
// fingerprinted as fingerprint, so a later revocation can spare it while
// that key stays authorized. Only writes the state file when the binding
// changed, because it is called for every request gitd serves.
func (r *Reconciler) Bind(machineKey, fingerprint string) error {
	machineKey = strings.TrimSpace(machineKey)
	fingerprint = strings.TrimSpace(fingerprint)
	if machineKey == "" || fingerprint == "" {
		return errors.New("reconciler: a binding needs a machine key and a fingerprint")
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if r.bindings[machineKey] == fingerprint {
		return nil
	}
	r.bindings[machineKey] = fingerprint
	return r.writeStateLocked()
}

// Reconciles on every trigger and on a timer until ctx is cancelled. Failures
// are logged and left for the next run, because the key set is only advanced
// once headscale has actually caught up.
func (r *Reconciler) Run(ctx context.Context) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.pending:
		case <-ticker.C:
		}
		runCtx, cancel := context.WithTimeout(ctx, reconcileTimeout)
		if err := r.Reconcile(runCtx); err != nil {
			r.logf("tailnet: reconcile headscale with pubkeys/: %v", err)
		}
		cancel()
	}
}

// Brings headscale in line with pubkeys/ once.
//
// Device nodes are expired when any key from the last reconciled set is gone,
// when there is no usable record of that set, or at the first push. The first
// push counts because, while the repository was empty, the CA page and hsproxy
// let any visitor join without a key in pubkeys/. The new set is recorded only
// after every expiry succeeded, so a failure is retried rather than
// forgotten.
func (r *Reconciler) Reconcile(ctx context.Context) error {
	current, err := r.authorizedKeys()
	if err != nil {
		return fmt.Errorf("read authorized keys: %w", err)
	}

	r.mu.Lock()
	previous := r.keys
	staleBinding := r.hasBindingOutsideLocked(current)
	r.mu.Unlock()

	switch {
	case previous == nil:
		r.logf("tailnet: no record of the last reconciled keys; dropping device nodes not seen with an authorized key")
	case len(previous) == 0 && len(current) > 0:
		r.logf("tailnet: first keys reached pubkeys/; dropping device nodes that joined while the repository was empty")
	case removedAny(previous, current), staleBinding:
		r.logf("tailnet: a key left pubkeys/; dropping device nodes not seen with an authorized key")
	default:
		return r.recordKeys(current, nil)
	}

	listed, err := r.dropUnauthorizedNodes(ctx, current)
	if err != nil {
		return err
	}
	return r.recordKeys(current, listed)
}

// Expires every device node not bound to a key in current, leaving gitd's own
// node in place. Returns the machine keys headscale listed, so bindings for
// nodes it has forgotten can be pruned.
func (r *Reconciler) dropUnauthorizedNodes(ctx context.Context, current []string) (map[string]struct{}, error) {
	nodes, err := r.nodes.ListNodes(ctx)
	if err != nil {
		return nil, err
	}
	authorized := make(map[string]struct{}, len(current))
	for _, key := range current {
		authorized[key] = struct{}{}
	}

	r.mu.Lock()
	bindings := make(map[string]string, len(r.bindings))
	for machineKey, fingerprint := range r.bindings {
		bindings[machineKey] = fingerprint
	}
	r.mu.Unlock()

	listed := make(map[string]struct{}, len(nodes))
	for _, node := range nodes {
		listed[node.MachineKey] = struct{}{}
		if !node.HasTag(DeviceTag) || node.HasTag(ServerTag) {
			continue
		}
		fingerprint, bound := bindings[node.MachineKey]
		if _, ok := authorized[fingerprint]; bound && ok {
			continue
		}
		if err := r.nodes.ExpireNode(ctx, node.ID); err != nil {
			return nil, err
		}
		r.logf("tailnet: expired device node %s (%s)", node.ID, node.Name)
		if bound {
			r.mu.Lock()
			delete(r.bindings, node.MachineKey)
			r.mu.Unlock()
		}
	}
	return listed, nil
}

// Reports whether gitd saw some node authenticate with a key that is no longer
// authorized. That is a revocation even when the key never made it into the
// recorded set, for instance when it was added and removed while gitd was
// down. Callers hold r.mu.
func (r *Reconciler) hasBindingOutsideLocked(current []string) bool {
	authorized := make(map[string]struct{}, len(current))
	for _, key := range current {
		authorized[key] = struct{}{}
	}
	for _, fingerprint := range r.bindings {
		if _, ok := authorized[fingerprint]; !ok {
			return true
		}
	}
	return false
}

// Records the key set just reconciled and, when listed is non-nil, drops
// bindings for nodes headscale no longer has.
func (r *Reconciler) recordKeys(keys []string, listed map[string]struct{}) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.keys = append([]string{}, keys...)
	if listed != nil {
		for machineKey := range r.bindings {
			if _, ok := listed[machineKey]; !ok {
				delete(r.bindings, machineKey)
			}
		}
	}
	return r.writeStateLocked()
}

// The state file's on-disk shape. Keys is null until a reconcile has
// recorded a set, which is what tells "nothing known" apart from "the
// repository authorized nobody".
type reconcileState struct {
	Keys  []string          `json:"keys"`
	Nodes map[string]string `json:"nodes"`
}

// Loads the last reconciled set and the bindings. A missing or unparseable
// file yields neither, both of which mean nothing is known about past state.
func (r *Reconciler) readState() ([]string, map[string]string) {
	empty := map[string]string{}
	raw, err := os.ReadFile(r.markerPath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			r.logf("tailnet: read reconcile state: %v", err)
		}
		return nil, empty
	}
	var state reconcileState
	if err := json.Unmarshal(raw, &state); err != nil {
		r.logf("tailnet: reconcile state is unreadable: %v", err)
		return nil, empty
	}
	if state.Nodes == nil {
		state.Nodes = empty
	}
	return state.Keys, state.Nodes
}

// Writes the state. Written to a temporary file and renamed so a crash
// mid-write leaves either the old state or the new one, never a truncated
// file that would read as missing. Callers hold r.mu.
func (r *Reconciler) writeStateLocked() error {
	var keys []string
	if r.keys != nil {
		keys = append([]string{}, r.keys...)
		sort.Strings(keys)
	}
	encoded, err := json.Marshal(reconcileState{Keys: keys, Nodes: r.bindings})
	if err != nil {
		return fmt.Errorf("encode reconcile state: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(r.markerPath), 0o700); err != nil {
		return fmt.Errorf("create reconcile state directory: %w", err)
	}
	temporary := r.markerPath + ".tmp"
	if err := os.WriteFile(temporary, encoded, 0o600); err != nil {
		return fmt.Errorf("write reconcile state: %w", err)
	}
	if err := os.Rename(temporary, r.markerPath); err != nil {
		return fmt.Errorf("replace reconcile state: %w", err)
	}
	return nil
}

// Reports whether any previously authorized key is missing from current.
func removedAny(previous []string, current []string) bool {
	present := make(map[string]struct{}, len(current))
	for _, key := range current {
		present[key] = struct{}{}
	}
	for _, key := range previous {
		if _, ok := present[key]; !ok {
			return true
		}
	}
	return false
}
