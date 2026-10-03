package tailnetlogin

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Stands in for a tsnet node: reports a scripted login state and records the
// keys it was asked to log in with.
type fakeNode struct {
	mu         sync.Mutex
	needsLogin bool
	stateErr   error
	loginErr   error
	logins     []string
}

func (n *fakeNode) NeedsLogin(context.Context) (bool, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.needsLogin, n.stateErr
}

func (n *fakeNode) Login(_ context.Context, authKey string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.logins = append(n.logins, authKey)
	if n.loginErr == nil {
		n.needsLogin = false
	}
	return n.loginErr
}

func (n *fakeNode) loggedInWith() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.logins...)
}

// Hands out numbered keys, or fails, and counts how often it was asked.
type fakeMinter struct {
	mu    sync.Mutex
	err   error
	calls int
}

func (m *fakeMinter) mint(context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	if m.err != nil {
		return "", m.err
	}
	return "key-" + string(rune('0'+m.calls)), nil
}

func (m *fakeMinter) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls
}

// A clock the test advances by hand, so cooldown behaviour is exact rather
// than a matter of sleeping.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// The headscale 0.29 map-poll failure for a node it no longer knows, as the
// tsnet backend logs it through its Logf.
const forgottenLog = "control: [v1] %s: %v"

var forgottenArgs = []any{"PollNetMap", errors.New("initial fetch failed 404: node not found")}

func newTestKeeper(t *testing.T, node *fakeNode, minter *fakeMinter) (*Keeper, *fakeClock) {
	t.Helper()
	clock := &fakeClock{now: time.Unix(1_700_000_000, 0)}
	keeper, err := New(Config{
		Node:     node,
		Mint:     minter.mint,
		Cooldown: time.Minute,
		Logf:     t.Logf,
	})
	if err != nil {
		t.Fatalf("build keeper: %v", err)
	}
	keeper.now = clock.Now
	return keeper, clock
}

// The ordinary recovery path: the node starts with state headscale has lost,
// asks to log in, and the keeper gets it a key without anyone re-pairing.
func TestNodeThatNeedsLoginIsLoggedInWithAFreshKey(t *testing.T) {
	node := &fakeNode{needsLogin: true}
	minter := &fakeMinter{}
	keeper, _ := newTestKeeper(t, node, minter)

	keeper.check(context.Background())

	if logins := node.loggedInWith(); len(logins) != 1 || logins[0] != "key-1" {
		t.Errorf("expected one login with the minted key, got %v", logins)
	}
}

// Minting is a request to hsproxy and consumes a headscale key. A healthy node
// must cost nothing, however often it is checked.
func TestRunningNodeIsLeftAlone(t *testing.T) {
	node := &fakeNode{}
	minter := &fakeMinter{}
	keeper, clock := newTestKeeper(t, node, minter)

	for range 3 {
		keeper.check(context.Background())
		clock.advance(time.Hour)
	}

	if minter.count() != 0 || len(node.loggedInWith()) != 0 {
		t.Errorf("a running node must not mint or log in, got %d mints and logins %v",
			minter.count(), node.loggedInWith())
	}
}

// A node that stays up while headscale forgets it never enters NeedsLogin: its
// map polls just fail with 404 and it keeps reporting Running on a stale map.
// That log line is the only signal, and it has to be acted on.
func TestNodeForgottenWhileRunningIsLoggedInAgain(t *testing.T) {
	node := &fakeNode{}
	minter := &fakeMinter{}
	keeper, _ := newTestKeeper(t, node, minter)

	keeper.ObserveLog(forgottenLog, forgottenArgs...)
	keeper.check(context.Background())

	if logins := node.loggedInWith(); len(logins) != 1 {
		t.Errorf("a forgotten node must log in again, got %v", logins)
	}
}

// tsnet logs a lot, including other control errors during ordinary network
// trouble. Only the control plane saying it does not know the node justifies
// spending a key.
func TestUnrelatedLogLinesDoNotTriggerLogin(t *testing.T) {
	node := &fakeNode{}
	minter := &fakeMinter{}
	keeper, _ := newTestKeeper(t, node, minter)

	keeper.ObserveLog("control: [v1] %s: %v", "PollNetMap", errors.New("dial tcp: connection refused"))
	keeper.ObserveLog("magicsock: endpoints changed: %v", "1.2.3.4:41641")
	keeper.check(context.Background())

	if minter.count() != 0 {
		t.Errorf("unrelated log lines must not mint, got %d mints", minter.count())
	}
}

// Without the relay or the tailnet there is no way to get a key. The node
// must not be handed an empty key, and the forgotten signal must survive so the
// next check retries once the control plane is back.
func TestFailedMintIsRetriedAfterTheCooldown(t *testing.T) {
	node := &fakeNode{}
	minter := &fakeMinter{err: errors.New("control plane unreachable")}
	keeper, clock := newTestKeeper(t, node, minter)

	keeper.ObserveLog(forgottenLog, forgottenArgs...)
	keeper.check(context.Background())
	if len(node.loggedInWith()) != 0 {
		t.Fatalf("a failed mint must not lead to a login, got %v", node.loggedInWith())
	}

	minter.mu.Lock()
	minter.err = nil
	minter.mu.Unlock()
	clock.advance(time.Minute)
	keeper.check(context.Background())

	if logins := node.loggedInWith(); len(logins) != 1 {
		t.Errorf("the keeper must retry once minting works again, got %v", logins)
	}
}

// tsnet passes through NeedsLogin briefly even while a login with a key is in
// flight. Without a cooldown every check in that window would mint another
// key that headscale then holds until it expires.
func TestCooldownStopsRepeatedMinting(t *testing.T) {
	node := &fakeNode{needsLogin: true, loginErr: errors.New("still starting")}
	minter := &fakeMinter{}
	keeper, clock := newTestKeeper(t, node, minter)

	keeper.check(context.Background())
	clock.advance(30 * time.Second)
	keeper.check(context.Background())
	if minter.count() != 1 {
		t.Fatalf("expected one mint inside the cooldown, got %d", minter.count())
	}

	clock.advance(30 * time.Second)
	keeper.check(context.Background())
	if minter.count() != 2 {
		t.Errorf("expected a second mint once the cooldown passed, got %d", minter.count())
	}
}

// If the node's own state cannot be read, nothing is known about whether it
// needs a key, so none is spent.
func TestUnreadableStateMintsNothing(t *testing.T) {
	node := &fakeNode{stateErr: errors.New("local API unavailable")}
	minter := &fakeMinter{}
	keeper, _ := newTestKeeper(t, node, minter)

	keeper.check(context.Background())

	if minter.count() != 0 {
		t.Errorf("an unreadable state must not mint, got %d mints", minter.count())
	}
}

// The forgotten signal arrives on tsnet's logging goroutine, not the keeper's.
// Run must pick it up promptly rather than at the next periodic check, which
// would leave the device off the tailnet for the whole interval.
func TestRunActsOnAForgottenNodeWithoutWaitingForTheInterval(t *testing.T) {
	node := &fakeNode{}
	minter := &fakeMinter{}
	keeper, err := New(Config{
		Node:     node,
		Mint:     minter.mint,
		Interval: time.Hour,
		Logf:     t.Logf,
	})
	if err != nil {
		t.Fatalf("build keeper: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		keeper.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	keeper.ObserveLog(forgottenLog, forgottenArgs...)

	deadline := time.Now().Add(5 * time.Second)
	for len(node.loggedInWith()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("Run must log the node in soon after it is forgotten")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Both collaborators are load-bearing: without a node there is nothing to log
// in, and without a minter the keeper would watch a stuck node forever.
func TestIncompleteConfigIsRejected(t *testing.T) {
	minter := &fakeMinter{}
	if _, err := New(Config{Mint: minter.mint}); err == nil {
		t.Error("a keeper without a node must be rejected")
	}
	if _, err := New(Config{Node: &fakeNode{}}); err == nil {
		t.Error("a keeper without a minter must be rejected")
	}
}
