package tailnetlogin

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"tailscale.com/ipn"
	"tailscale.com/ipn/store"
	"tailscale.com/tsnet"
)

// Starts a tsnet node and keeps it logged in until ctx ends.
//
// Must be called before the node is started, because the forgotten-node signal
// only exists in the backend log and tsnet reads Logf once at start, and
// because a node that has never logged in must be handed its key before it
// starts. The node's existing Logf still receives every line. Callers then
// wait on server.Up as usual; Up needs no AuthKey unless the caller already
// holds one.
//
// Fails without starting the node when it has never logged in and no key can
// be minted, since such a node could only wait for a login nobody completes.
func Keep(ctx context.Context, server *tsnet.Server, mint MintFunc, logf func(string, ...any)) error {
	if server == nil {
		return errors.New("tailnetlogin: a tsnet server is required")
	}
	keeper, err := New(Config{Node: tsnetNode{server: server}, Mint: mint, Logf: logf})
	if err != nil {
		return err
	}

	storeLogf := server.Logf
	if storeLogf == nil {
		storeLogf = func(string, ...any) {}
	}
	firstLogin, err := prepareFirstLogin(ctx, server, mint, storeLogf)
	if err != nil {
		return err
	}
	if firstLogin && server.AuthKey != "" {
		keeper.deferFirstAttempt()
	}

	backendLogf := server.Logf
	server.Logf = func(format string, args ...any) {
		keeper.ObserveLog(format, args...)
		if backendLogf != nil {
			backendLogf(format, args...)
		}
	}
	if err := server.Start(); err != nil {
		return fmt.Errorf("start the tailnet node: %w", err)
	}

	go keeper.Run(ctx)
	return nil
}

// Gives a node that has never logged in its key before tsnet starts, and
// reports whether this is such a first login.
//
// Restarting the backend with a key once a fresh node sits in NeedsLogin, as
// the keeper does for known nodes, leaves the new control client never
// registering. A key set on the server before Start is the path tsnet
// supports. Nodes with a saved profile mint nothing here: they may be offline,
// and the CLI agent restarts on every git command after going idle.
//
// Opens the node's state store itself, at the path tsnet would use, and hands
// it to the server so both read the same state. The store's own log lines go
// to logf, which is backend noise for most callers.
func prepareFirstLogin(ctx context.Context, server *tsnet.Server, mint MintFunc, logf func(string, ...any)) (bool, error) {
	if server.Store == nil {
		if server.Dir == "" {
			return false, errors.New("tailnetlogin: the tsnet server needs a state directory")
		}
		stateStore, err := store.New(logf, filepath.Join(server.Dir, "tailscaled.state"))
		if err != nil {
			return false, fmt.Errorf("open the tailnet state: %w", err)
		}
		server.Store = stateStore
	}

	_, err := server.Store.ReadState(ipn.CurrentProfileStateKey)
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, ipn.ErrStateNotExist) {
		return false, fmt.Errorf("read the tailnet login state: %w", err)
	}
	if server.AuthKey != "" {
		return true, nil
	}

	mintCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()
	key, err := mint(mintCtx)
	if err != nil {
		return false, fmt.Errorf("obtain a key for the first tailnet login: %w", err)
	}
	server.AuthKey = key
	return true, nil
}

// Drives a tsnet node through its LocalAPI client.
type tsnetNode struct {
	server *tsnet.Server
}

func (n tsnetNode) NeedsLogin(ctx context.Context) (bool, error) {
	client, err := n.server.LocalClient()
	if err != nil {
		return false, err
	}
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		return false, err
	}
	return status.BackendState == ipn.NeedsLogin.String(), nil
}

// Restarts the backend with the key, keeping the node's stored prefs and
// identity.
//
// Start builds a new control client carrying the key, and logs in at once if
// the node still has a node key. A node without one lands in NeedsLogin
// instead, so the login is started explicitly, the same way tsnet.Server
// itself handles a key on first start.
func (n tsnetNode) Login(ctx context.Context, authKey string) error {
	client, err := n.server.LocalClient()
	if err != nil {
		return err
	}
	if err := client.Start(ctx, ipn.Options{AuthKey: authKey}); err != nil {
		return fmt.Errorf("restart the tailnet backend with a new key: %w", err)
	}
	needsLogin, err := n.NeedsLogin(ctx)
	if err != nil {
		return err
	}
	if needsLogin {
		if err := client.StartLoginInteractive(ctx); err != nil {
			return fmt.Errorf("start login with a new key: %w", err)
		}
	}
	return nil
}
