package tailnetlogin

import (
	"context"
	"errors"
	"fmt"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// Starts a tsnet node and keeps it logged in until ctx ends.
//
// Must be called before the node is started, because the forgotten-node signal
// only exists in the backend log and tsnet reads Logf once at start. The node's
// existing Logf still receives every line. Callers then wait on server.Up as
// usual; a node that needs a key to join gets one from the keeper, so Up needs
// no AuthKey unless the caller already holds one.
func Keep(ctx context.Context, server *tsnet.Server, mint MintFunc, logf func(string, ...any)) error {
	if server == nil {
		return errors.New("tailnetlogin: a tsnet server is required")
	}
	keeper, err := New(Config{Node: tsnetNode{server: server}, Mint: mint, Logf: logf})
	if err != nil {
		return err
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
