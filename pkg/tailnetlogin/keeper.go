// Package tailnetlogin keeps a tsnet node logged in to a headscale that may
// forget it.
//
// headscale's database is a cache of pubkeys/ in the repository, not a source
// of truth. It can be wiped and rebuilt, and gitd deletes every device node
// whenever a key leaves pubkeys/. Either way a node that was fine a moment ago
// is unknown to the control plane, and the device's only recovery is a fresh
// single-use key, which it can mint for itself while its certificate is still
// in pubkeys/.
//
// Two different symptoms mean the same thing. A node that starts on state
// headscale no longer has asks to log in (NeedsLogin). A node that was already
// running never does: its map polls fail with 404 and it keeps reporting
// Running on a stale network map. The keeper watches for both.
package tailnetlogin

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync/atomic"
	"time"
)

// How often the node's login state is checked when nothing else prompts it.
const defaultInterval = 5 * time.Second

// The least time between two login attempts. tsnet passes through NeedsLogin
// briefly while a key login is in flight, and each attempt spends a key that
// headscale holds until it expires, so attempts are spaced out.
const defaultCooldown = 30 * time.Second

// Bounds one mint-and-login attempt so a hung control plane cannot wedge the
// keeper.
const attemptTimeout = time.Minute

// How headscale 0.29 answers a map poll for a node key it does not know, as
// the Tailscale control client logs it. Both "node not found" and a node key
// bound to another machine come back as 404.
const forgottenNodeLog = "initial fetch failed 404"

// The parts of a tailnet node the keeper drives. LocalNode implements it for
// tsnet; the interface exists so the policy can be tested without a tailnet.
type Node interface {
	NeedsLogin(ctx context.Context) (bool, error)
	Login(ctx context.Context, authKey string) error
}

// Obtains a fresh single-use key for this node: from hsproxy over mTLS on a
// device, or from the headscale API on gitd.
type MintFunc func(ctx context.Context) (string, error)

type Config struct {
	Node Node
	Mint MintFunc

	// Optional; zero means the defaults above.
	Interval time.Duration
	Cooldown time.Duration

	// Optional. Defaults to the standard logger.
	Logf func(format string, args ...any)
}

// Re-logs a node in whenever the control plane has forgotten it.
type Keeper struct {
	node     Node
	mint     MintFunc
	interval time.Duration
	cooldown time.Duration
	logf     func(format string, args ...any)
	now      func() time.Time

	// Set from tsnet's logging goroutine, consumed by Run.
	forgotten atomic.Bool
	wake      chan struct{}

	// Only touched by the goroutine running checks.
	lastAttempt time.Time
}

func New(config Config) (*Keeper, error) {
	if config.Node == nil {
		return nil, errors.New("tailnetlogin: a node is required")
	}
	if config.Mint == nil {
		return nil, errors.New("tailnetlogin: a key minter is required")
	}
	interval := config.Interval
	if interval <= 0 {
		interval = defaultInterval
	}
	cooldown := config.Cooldown
	if cooldown <= 0 {
		cooldown = defaultCooldown
	}
	logf := config.Logf
	if logf == nil {
		logf = log.Printf
	}
	return &Keeper{
		node:     config.Node,
		mint:     config.Mint,
		interval: interval,
		cooldown: cooldown,
		logf:     logf,
		now:      time.Now,
		wake:     make(chan struct{}, 1),
	}, nil
}

// Holds off the first login attempt for one cooldown.
//
// A node started with a key reports NeedsLogin until that login completes.
// Treating that as a lost node would restart the backend mid-login, which on a
// node that has never logged in leaves it never registering. Must be called
// before Run.
func (k *Keeper) deferFirstAttempt() {
	k.lastAttempt = k.now()
}

// Watches tsnet's backend log for the control plane disowning the node.
//
// Meant to be installed as tsnet.Server.Logf, which is the only place a
// running node's 404 map polls are visible: they never reach the IPN bus or
// change the backend state.
func (k *Keeper) ObserveLog(format string, args ...any) {
	if !strings.Contains(fmt.Sprintf(format, args...), forgottenNodeLog) {
		return
	}
	k.forgotten.Store(true)
	select {
	case k.wake <- struct{}{}:
	default:
	}
}

// Checks the node periodically and whenever it is reported forgotten, until
// the context ends.
func (k *Keeper) Run(ctx context.Context) {
	ticker := time.NewTicker(k.interval)
	defer ticker.Stop()

	for {
		k.check(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-k.wake:
		}
	}
}

// One pass: if the node needs a key and the cooldown has passed, mint one and
// log in with it.
func (k *Keeper) check(ctx context.Context) {
	if !k.lastAttempt.IsZero() && k.now().Sub(k.lastAttempt) < k.cooldown {
		return
	}

	if !k.forgotten.Load() {
		needsLogin, err := k.node.NeedsLogin(ctx)
		if err != nil {
			k.logf("tailnetlogin: could not read the node's login state: %v", err)
			return
		}
		if !needsLogin {
			return
		}
	}

	k.lastAttempt = k.now()
	attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()

	key, err := k.mint(attemptCtx)
	if err != nil {
		k.logf("tailnetlogin: the control plane no longer knows this node, "+
			"and a new key could not be obtained: %v", err)
		return
	}
	if err := k.node.Login(attemptCtx, key); err != nil {
		k.logf("tailnetlogin: logging in with a new key failed: %v", err)
		return
	}
	k.forgotten.Store(false)
	k.logf("tailnetlogin: logged in again with a new key")
}
