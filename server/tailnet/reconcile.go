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

	// Where the last reconciled key set is recorded. It is only a cache: a
	// missing or unreadable marker costs one round of device re-enrollment,
	// never a missed revocation.
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
// headscale cannot record which pubkey a node belongs to: tailnet hostnames are
// chosen by devices and do not match pubkey file names, and tags are fixed by
// the policy file. So a revocation expires every tag:device node. The devices
// that are still authorized see they need to log in, ask hsproxy for a fresh
// key with their certificate, and come straight back; the revoked one cannot.
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
	return &Reconciler{
		nodes:          config.Nodes,
		authorizedKeys: config.AuthorizedKeys,
		markerPath:     markerPath,
		interval:       interval,
		logf:           logf,
		pending:        make(chan struct{}, 1),
	}, nil
}

// Asks for a reconcile soon. Called after every push; never blocks.
func (r *Reconciler) Trigger() {
	select {
	case r.pending <- struct{}{}:
	default:
	}
}

// Reconciles on every trigger and on a timer until ctx is cancelled. Failures
// are logged and left for the next run, because the marker is only advanced
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

	previous, known := r.readMarker()
	switch {
	case !known:
		r.logf("tailnet: no record of the last reconciled keys; dropping device nodes so only authorized devices re-enroll")
	case len(previous) == 0 && len(current) > 0:
		r.logf("tailnet: first keys reached pubkeys/; dropping device nodes that joined while the repository was empty")
	case removedAny(previous, current):
		r.logf("tailnet: a key left pubkeys/; dropping device nodes so the revoked device cannot stay on the tailnet")
	default:
		return r.writeMarker(current)
	}

	if err := r.dropDeviceNodes(ctx); err != nil {
		return err
	}
	return r.writeMarker(current)
}

// Expires every node tagged as a device, leaving gitd's own node in place.
func (r *Reconciler) dropDeviceNodes(ctx context.Context) error {
	nodes, err := r.nodes.ListNodes(ctx)
	if err != nil {
		return err
	}
	for _, node := range nodes {
		if !node.HasTag(DeviceTag) || node.HasTag(ServerTag) {
			continue
		}
		if err := r.nodes.ExpireNode(ctx, node.ID); err != nil {
			return err
		}
		r.logf("tailnet: expired device node %s (%s)", node.ID, node.Name)
	}
	return nil
}

// The marker's on-disk shape. A struct rather than a bare list so a future
// field does not make old markers unreadable.
type reconcileMarker struct {
	Keys []string `json:"keys"`
}

// Loads the last reconciled set. Reports false for a missing or unparseable
// marker, both of which mean nothing is known about past state.
func (r *Reconciler) readMarker() (map[string]struct{}, bool) {
	raw, err := os.ReadFile(r.markerPath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			r.logf("tailnet: read reconcile marker: %v", err)
		}
		return nil, false
	}
	var marker reconcileMarker
	if err := json.Unmarshal(raw, &marker); err != nil {
		r.logf("tailnet: reconcile marker is unreadable: %v", err)
		return nil, false
	}
	keys := make(map[string]struct{}, len(marker.Keys))
	for _, key := range marker.Keys {
		keys[key] = struct{}{}
	}
	return keys, true
}

// Records the set just reconciled. Written to a temporary file and renamed so
// a crash mid-write leaves either the old marker or the new one, never a
// truncated file that would read as missing.
func (r *Reconciler) writeMarker(keys []string) error {
	sorted := append([]string(nil), keys...)
	sort.Strings(sorted)
	encoded, err := json.Marshal(reconcileMarker{Keys: sorted})
	if err != nil {
		return fmt.Errorf("encode reconcile marker: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(r.markerPath), 0o700); err != nil {
		return fmt.Errorf("create reconcile marker directory: %w", err)
	}
	temporary := r.markerPath + ".tmp"
	if err := os.WriteFile(temporary, encoded, 0o600); err != nil {
		return fmt.Errorf("write reconcile marker: %w", err)
	}
	if err := os.Rename(temporary, r.markerPath); err != nil {
		return fmt.Errorf("replace reconcile marker: %w", err)
	}
	return nil
}

// Reports whether any previously authorized key is missing from current.
func removedAny(previous map[string]struct{}, current []string) bool {
	present := make(map[string]struct{}, len(current))
	for _, key := range current {
		present[key] = struct{}{}
	}
	for key := range previous {
		if _, ok := present[key]; !ok {
			return true
		}
	}
	return false
}
