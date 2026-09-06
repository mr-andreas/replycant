package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"

	"tailscale.com/ipn/ipnstate"
)

// Event types on stdout. Electron reads stdout as a stream of these rather
// than a single readiness line, because the tailnet's health changes over the
// life of the process and the app has to be able to say so.
const (
	readyEventType  = "ready"
	statusEventType = "status"
)

// What to report when the node itself will not say.
//
// Distinct from any of tailscale's own backend states, so the desktop app can
// tell "the node says it is not connected" from "the node is not answering".
const backendStateUnknown = "Unknown"

// How often to poll the node.
//
// Chosen to be responsive enough that a user watching the panel sees a peer go
// offline without wondering whether the panel is stuck, while staying far
// below anything that would matter for a local IPC call.
const statusInterval = 5 * time.Second

// A snapshot of the tailnet, as the desktop app presents it.
//
// This exists because the app previously had no way to distinguish "this
// device is not on the tailnet" from "this device is on the tailnet but the
// server is down". Both showed up as failed requests, and the user's only
// recourse was to re-pair. Every field here is chosen to make that distinction
// visible rather than to expose tailscale internals.
type statusEvent struct {
	Type string `json:"type"`

	// One of tailscale's states, or backendStateUnknown when the node did not
	// answer. "Running" is the only one that means traffic can flow.
	BackendState string `json:"backend_state"`

	TailnetIPs []string `json:"tailnet_ips"`

	// The DERP region carrying this node's traffic. Present even on a direct
	// connection, because DERP is still the fallback path.
	DERPHome string `json:"derp_home"`

	// Which path the shim's most recent control session took. Not part of
	// tailscale's status, because the shim owns the choice: a device stuck on
	// the relay is a deployment problem with no other visible symptom.
	ControlRoute string `json:"control_route"`

	Peers       int `json:"peers"`
	PeersOnline int `json:"peers_online"`

	// tailscale's own warnings. A node can be Running and still unable to
	// carry traffic, which would otherwise look like a healthy tailnet and a
	// broken server.
	Health []string `json:"health,omitempty"`

	// Why the last poll failed, if it did. Reported rather than dropped so the
	// panel does not freeze on the last good reading.
	LastError string `json:"last_error,omitempty"`
}

// Projects a tailscale status onto what the app shows.
//
// Separate from the polling loop so the mapping can be tested without standing
// up a WireGuard node, and tolerant of a partially started node because status
// is polled from the moment the sidecar starts.
func newStatusEvent(status *ipnstate.Status, route string, queryErr error) statusEvent {
	event := statusEvent{
		Type:         statusEventType,
		BackendState: backendStateUnknown,
		ControlRoute: route,
	}
	if queryErr != nil {
		event.LastError = queryErr.Error()
	}
	if status == nil {
		return event
	}

	event.BackendState = status.BackendState
	event.Health = status.Health
	for _, ip := range status.TailscaleIPs {
		event.TailnetIPs = append(event.TailnetIPs, ip.String())
	}
	if status.Self != nil {
		event.DERPHome = status.Self.Relay
	}
	event.Peers = len(status.Peer)
	for _, peer := range status.Peer {
		if peer != nil && peer.Online {
			event.PeersOnline++
		}
	}
	return event
}

// Where a status snapshot comes from.
//
// Both are functions so the loop can be driven in tests, and because the
// route is owned by the shim while the status is owned by the node.
type statusPoller struct {
	Interval time.Duration
	Status   func(context.Context) (*ipnstate.Status, error)
	Route    func() string
}

// Streams status until the context is cancelled.
//
// Emits immediately and then on the interval, so the desktop app has something
// to render as soon as the node is up rather than an empty panel for the first
// interval. A failed poll is emitted like any other reading: the node not
// answering is the status.
func publishStatus(ctx context.Context, out io.Writer, poller statusPoller) {
	interval := poller.Interval
	if interval <= 0 {
		interval = statusInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		status, err := poller.Status(ctx)
		route := ""
		if poller.Route != nil {
			route = poller.Route()
		}
		if writeErr := emit(out, newStatusEvent(status, route, err)); writeErr != nil {
			// stdout closing means the parent is gone, so there is no one left
			// to report to.
			log.Printf("stopping status stream: %v", writeErr)
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Writes one event as a single stdout line.
//
// The parent parses stdout line by line, so a partial or multi-line write
// would leave it unable to parse either that event or the next one.
func emit(out io.Writer, event any) error {
	encoded, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("encode sidecar event: %w", err)
	}
	if _, err := fmt.Fprintf(out, "%s\n", encoded); err != nil {
		return fmt.Errorf("write sidecar event: %w", err)
	}
	return nil
}
