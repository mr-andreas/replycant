package tailnetlogin

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/ipn/store"
	"tailscale.com/tsnet"
)

// A node that has never logged in must get its key before tsnet starts. The
// alternative, restarting the backend with a key once it sits in NeedsLogin,
// leaves the new control client never registering, which is how the first
// device ended up with no gitd to push to.
func TestFreshNodeIsGivenAKeyBeforeItStarts(t *testing.T) {
	server := &tsnet.Server{Dir: t.TempDir()}
	minter := &fakeMinter{}

	fresh, err := prepareFirstLogin(context.Background(), server, minter.mint, t.Logf)

	if err != nil {
		t.Fatalf("prepare first login: %v", err)
	}
	if !fresh {
		t.Error("an empty state directory must count as a first login")
	}
	if server.AuthKey != "key-1" || minter.count() != 1 {
		t.Errorf("expected one mint landing in AuthKey, got key %q after %d mints",
			server.AuthKey, minter.count())
	}
}

// A device that has logged in before starts from its saved profile, possibly
// offline, and the CLI agent restarts on every git command after going idle.
// Minting there would cost a round trip and a headscale key each time.
func TestNodeWithASavedLoginMintsNothing(t *testing.T) {
	dir := t.TempDir()
	saved, err := store.New(t.Logf, filepath.Join(dir, "tailscaled.state"))
	if err != nil {
		t.Fatalf("open state store: %v", err)
	}
	if err := saved.WriteState(ipn.CurrentProfileStateKey, []byte("profile-1")); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	server := &tsnet.Server{Dir: dir}
	minter := &fakeMinter{}

	fresh, err := prepareFirstLogin(context.Background(), server, minter.mint, t.Logf)

	if err != nil {
		t.Fatalf("prepare first login: %v", err)
	}
	if fresh || server.AuthKey != "" || minter.count() != 0 {
		t.Errorf("a saved login must mint nothing, got fresh=%v key %q after %d mints",
			fresh, server.AuthKey, minter.count())
	}
}

// The first desktop device and gitd arrive with a key already. Minting another
// would waste a headscale key and replace the one the caller chose.
func TestSuppliedKeyIsKept(t *testing.T) {
	server := &tsnet.Server{Dir: t.TempDir(), AuthKey: "supplied"}
	minter := &fakeMinter{}

	fresh, err := prepareFirstLogin(context.Background(), server, minter.mint, t.Logf)

	if err != nil {
		t.Fatalf("prepare first login: %v", err)
	}
	if !fresh {
		t.Error("an empty state directory must count as a first login even with a key")
	}
	if server.AuthKey != "supplied" || minter.count() != 0 {
		t.Errorf("a supplied key must be kept, got %q after %d mints", server.AuthKey, minter.count())
	}
}

// A node that has never logged in cannot join without a key, so a failed mint
// is reported to the caller instead of starting a node that would only wait.
func TestFailedFirstMintIsReturned(t *testing.T) {
	server := &tsnet.Server{Dir: t.TempDir()}
	minter := &fakeMinter{err: errors.New("hsproxy unreachable")}

	_, err := prepareFirstLogin(context.Background(), server, minter.mint, t.Logf)

	if err == nil || server.AuthKey != "" {
		t.Errorf("a failed first mint must be returned with no key set, got err %v and key %q",
			err, server.AuthKey)
	}
}
