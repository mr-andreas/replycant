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
			key.NewNode().Public(): {HostName: "gitd", DNSName: "gitd.replycant.internal.", Online: true, CurAddr: "192.0.2.10:41641"},
			key.NewNode().Public(): {HostName: "phone", Online: false},
		},
	}
}

// The whole point of the status panel is telling "not connected" apart from
// "connected but the server is down", which is the distinction users cannot
// make today. Everything the panel shows comes from this mapping.
func TestStatusReportsWhatTheUserNeedsToTellFailuresApart(t *testing.T) {
	event := newStatusEvent(runningStatus(), nil)

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
	if event.ServerPath != "direct" {
		t.Errorf("server path = %q, want direct", event.ServerPath)
	}
}

// A device whose control session goes through the hosted relay can still
// have a direct WireGuard path to gitd, and the panel is the only place
// that hop is visible.
func TestStatusReportsADirectPathWhenGitdHasACurrentAddress(t *testing.T) {
	event := newStatusEvent(runningStatus(), nil)
	if event.ServerPath != "direct" {
		t.Errorf("server path = %q, want direct", event.ServerPath)
	}
	if event.ServerRelay != "" {
		t.Errorf("server relay = %q, want empty on a direct path", event.ServerRelay)
	}
}

// Empty CurAddr with a Relay region is Tailscale's DERP hop. Showing
// the region is what keeps "hel" distinct from a direct connection.
func TestStatusReportsARelayPathWhenGitdHasNoCurrentAddress(t *testing.T) {
	status := runningStatus()
	for _, peer := range status.Peer {
		if peer.HostName == "gitd" {
			peer.CurAddr = ""
			peer.Relay = "hel"
		}
	}

	event := newStatusEvent(status, nil)
	if event.ServerPath != "relay" {
		t.Errorf("server path = %q, want relay", event.ServerPath)
	}
	if event.ServerRelay != "hel" {
		t.Errorf("server relay = %q, want hel", event.ServerRelay)
	}
}

// gitd being present but offline is the case the panel exists for: the
// device is on the tailnet and the server is down.
func TestStatusReportsOfflineWhenGitdIsNotOnline(t *testing.T) {
	status := runningStatus()
	for _, peer := range status.Peer {
		if peer.HostName == "gitd" {
			peer.Online = false
			peer.Relay = "hel"
		}
	}

	event := newStatusEvent(status, nil)
	if event.ServerPath != "offline" {
		t.Errorf("server path = %q, want offline", event.ServerPath)
	}
}

// Status is read before peers appear. Claiming a path to a server that
// has not been seen would be a guess.
func TestStatusHidesTheServerPathWhenGitdIsMissing(t *testing.T) {
	status := runningStatus()
	for id, peer := range status.Peer {
		if peer.HostName == "gitd" {
			delete(status.Peer, id)
		}
	}

	event := newStatusEvent(status, nil)
	if event.ServerPath != "" {
		t.Errorf("server path = %q, want empty", event.ServerPath)
	}
}

// Health warnings are how tailscale reports a node that is nominally running
// but cannot actually carry traffic, which would otherwise look like a healthy
// tailnet and a broken server.
func TestStatusCarriesHealthWarnings(t *testing.T) {
	status := runningStatus()
	status.Health = []string{"DERP region fra is unreachable"}

	event := newStatusEvent(status, nil)
	if len(event.Health) != 1 || !strings.Contains(event.Health[0], "unreachable") {
		t.Errorf("health = %v", event.Health)
	}
}

// A failed status query is itself the status: the node is not answering. It
// must be reported rather than dropped, or the panel would freeze on the last
// good reading and claim everything is fine.
func TestStatusReportsAFailedQuery(t *testing.T) {
	event := newStatusEvent(nil, errors.New("node is not answering"))

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
	event := newStatusEvent(&ipnstate.Status{BackendState: "Starting"}, nil)

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
