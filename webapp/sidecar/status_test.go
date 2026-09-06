package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

// A status the way the node would report it once it is fully up.
func runningStatus() *ipnstate.Status {
	return &ipnstate.Status{
		BackendState: "Running",
		TailscaleIPs: []netip.Addr{
			netip.MustParseAddr("100.64.0.2"),
			netip.MustParseAddr("fd7a:115c:a1e0::2"),
		},
		Self: &ipnstate.PeerStatus{Relay: "fra"},
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			key.NewNode().Public(): {HostName: "gitd", Online: true},
			key.NewNode().Public(): {HostName: "phone", Online: false},
		},
	}
}

// The whole point of the status panel is telling "not connected" apart from
// "connected but the server is down", which is the distinction users cannot
// make today. Everything the panel shows comes from this mapping.
func TestStatusReportsWhatTheUserNeedsToTellFailuresApart(t *testing.T) {
	event := newStatusEvent(runningStatus(), "tailnet", nil)

	if event.Type != statusEventType {
		t.Errorf("event type = %q, want %q", event.Type, statusEventType)
	}
	if event.BackendState != "Running" {
		t.Errorf("backend state = %q", event.BackendState)
	}
	if len(event.TailnetIPs) != 2 || event.TailnetIPs[0] != "100.64.0.2" {
		t.Errorf("tailnet IPs = %v", event.TailnetIPs)
	}
	if event.DERPHome != "fra" {
		t.Errorf("DERP home = %q", event.DERPHome)
	}
	if event.Peers != 2 || event.PeersOnline != 1 {
		t.Errorf("peers = %d, online = %d", event.Peers, event.PeersOnline)
	}
}

// Which path control traffic took is the one thing tailscale's own status
// cannot report, because the shim owns that choice. It is worth surfacing: a
// device permanently on the relay is a deployment problem the user can see no
// other way.
func TestStatusReportsWhichControlPathWasUsed(t *testing.T) {
	if got := newStatusEvent(runningStatus(), "relay", nil).ControlRoute; got != "relay" {
		t.Errorf("control route = %q, want relay", got)
	}
	if got := newStatusEvent(runningStatus(), "tailnet", nil).ControlRoute; got != "tailnet" {
		t.Errorf("control route = %q, want tailnet", got)
	}
}

// Health warnings are how tailscale reports a node that is nominally running
// but cannot actually carry traffic, which would otherwise look like a healthy
// tailnet and a broken server.
func TestStatusCarriesHealthWarnings(t *testing.T) {
	status := runningStatus()
	status.Health = []string{"DERP region fra is unreachable"}

	event := newStatusEvent(status, "tailnet", nil)
	if len(event.Health) != 1 || !strings.Contains(event.Health[0], "unreachable") {
		t.Errorf("health = %v", event.Health)
	}
}

// A failed status query is itself the status: the node is not answering. It
// must be reported rather than dropped, or the panel would freeze on the last
// good reading and claim everything is fine.
func TestStatusReportsAFailedQuery(t *testing.T) {
	event := newStatusEvent(nil, "relay", errors.New("node is not answering"))

	if event.BackendState != backendStateUnknown {
		t.Errorf("backend state = %q, want %q", event.BackendState, backendStateUnknown)
	}
	if !strings.Contains(event.LastError, "not answering") {
		t.Errorf("last error = %q", event.LastError)
	}
}

// The node reports no Self until it has joined, and a panel that crashed the
// sidecar during startup would take the tailnet down with it.
func TestStatusToleratesAPartiallyStartedNode(t *testing.T) {
	event := newStatusEvent(&ipnstate.Status{BackendState: "Starting"}, "", nil)

	if event.BackendState != "Starting" {
		t.Errorf("backend state = %q", event.BackendState)
	}
	if event.DERPHome != "" || len(event.TailnetIPs) != 0 {
		t.Errorf("a starting node has no addresses or relay yet, got %+v", event)
	}
}

// Serialises writes to stdout.
//
// Status is emitted from a poller while the readiness line comes from the main
// goroutine, so without one writer the two could interleave mid-line and the
// parent would fail to parse either.
type recordingWriter struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (w *recordingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.Write(p)
}

func (w *recordingWriter) lines() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	text := strings.TrimSuffix(w.buf.String(), "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

// The panel has to keep up with a tailnet that changes underneath it - a peer
// going offline, a DERP region changing - so status is pushed on an interval
// rather than only at startup.
func TestPublishStatusEmitsRepeatedly(t *testing.T) {
	writer := &recordingWriter{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	queries := make(chan struct{}, 8)
	done := make(chan struct{})
	go func() {
		defer close(done)
		publishStatus(ctx, writer, statusPoller{
			Interval: time.Millisecond,
			Status: func(context.Context) (*ipnstate.Status, error) {
				select {
				case queries <- struct{}{}:
				default:
				}
				return runningStatus(), nil
			},
			Route: func() string { return "tailnet" },
		})
	}()

	for i := 0; i < 3; i++ {
		select {
		case <-queries:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d status queries arrived", i)
		}
	}
	cancel()
	<-done

	lines := writer.lines()
	if len(lines) < 3 {
		t.Fatalf("expected repeated status lines, got %d", len(lines))
	}
	for _, line := range lines {
		var event statusEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("every stdout line must be one JSON event: %v (%q)", err, line)
		}
		if event.Type != statusEventType {
			t.Errorf("line %q is not a status event", line)
		}
	}
}

// A node that stops answering must not stop the stream: the report that it
// stopped answering is exactly what the user needs to see.
func TestPublishStatusKeepsGoingAfterAFailedQuery(t *testing.T) {
	writer := &recordingWriter{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var calls int
	var mu sync.Mutex
	emitted := make(chan struct{}, 4)
	done := make(chan struct{})
	go func() {
		defer close(done)
		publishStatus(ctx, writer, statusPoller{
			Interval: time.Millisecond,
			Status: func(context.Context) (*ipnstate.Status, error) {
				mu.Lock()
				calls++
				failing := calls == 1
				mu.Unlock()
				select {
				case emitted <- struct{}{}:
				default:
				}
				if failing {
					return nil, errors.New("node is not answering")
				}
				return runningStatus(), nil
			},
			Route: func() string { return "relay" },
		})
	}()

	for i := 0; i < 2; i++ {
		select {
		case <-emitted:
		case <-time.After(2 * time.Second):
			t.Fatal("the poller stopped after a failed query")
		}
	}
	cancel()
	<-done

	lines := writer.lines()
	if len(lines) < 2 {
		t.Fatalf("expected the failure and a later success, got %d lines", len(lines))
	}
	var first statusEvent
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("decode first line: %v", err)
	}
	if first.LastError == "" {
		t.Error("the first line must report the failed query")
	}
}

// Electron distinguishes events by type, so the readiness line has to carry
// one too. Without it the parent cannot tell readiness from status and would
// treat a status line as a missing-SOCKS-details readiness message.
func TestReadyIsATypedEvent(t *testing.T) {
	var out bytes.Buffer
	if err := announce(&out, ready{
		SocksAddr:     "127.0.0.1:41234",
		SocksUsername: "tsnet",
		SocksPassword: "deadbeef",
	}); err != nil {
		t.Fatalf("announce must succeed: %v", err)
	}

	var decoded struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("the readiness line must be valid JSON: %v", err)
	}
	if decoded.Type != readyEventType {
		t.Errorf("readiness type = %q, want %q", decoded.Type, readyEventType)
	}
}
