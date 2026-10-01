package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/pkg/tailnetagent"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestImporterRefusesRepoWithoutTailnetConfig documents that an older clone,
// which never joined the tailnet, cannot upload. There is no direct dial to
// fall back on.
func TestImporterRefusesRepoWithoutTailnetConfig(t *testing.T) {
	repo := initTempRepo(t)
	mustRun(t, repo, "git", "remote", "set-url", "origin", "replycant::https://gitd.replycant.internal:8443/repo.git")
	imp, _, _, _ := newTestImporter(t, nil)
	imp.uploadObjects = nil

	err := imp.setupCryptoAndUploader(context.Background(), repo)
	require.Error(t, err)
	assert.ErrorIs(t, err, tailnetagent.ErrNotConfigured)
}

// TestImporterLFSUsesTailnetProxy strips the helper prefix before deriving
// the LFS endpoint and dials that endpoint through the repository agent.
// A direct client would never call the agent's dialer.
func TestImporterLFSUsesTailnetProxy(t *testing.T) {
	repo := initTempRepo(t)
	origin := "replycant::https://gitd.replycant.internal:8443/repo.git"
	mustRun(t, repo, "git", "remote", "set-url", "origin", origin)

	var dials atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(backend.Close)
	armImporterTailnet(t, repo, func(ctx context.Context, network, addr string) (net.Conn, error) {
		dials.Add(1)
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	})

	imp, _, _, _ := newTestImporter(t, nil)
	imp.uploadObjects = nil
	require.NoError(t, imp.setupCryptoAndUploader(context.Background(), repo))

	client, endpoint, err := tailnetLFSClient(context.Background(), imp, repo, origin)
	require.NoError(t, err)
	assert.Equal(t, "gitd.replycant.internal:8443", endpoint.BaseURL.Host)
	assert.Equal(t, "/lfs", endpoint.BaseURL.Path)
	assert.Equal(t, "https", endpoint.BaseURL.Scheme)

	resp, err := client.Get(backend.URL)
	require.NoError(t, err)
	_ = resp.Body.Close()
	assert.Greater(t, dials.Load(), int32(0))
}

// armImporterTailnet holds the repository lock with an in-process proxy so
// the importer reuses it instead of spawning a real node.
func armImporterTailnet(t *testing.T, repo string, dial tailnetagent.DialFunc) {
	t.Helper()
	gitDir := importerGitDir(t, repo)
	require.NoError(t, tailnetagent.SaveConfig(gitDir, tailnetagent.PersistedConfig{
		HeadscaleAddr:       "headscale.example:443",
		HeadscaleServerName: "headscale.example",
		Hostname:            "importer-test-device",
	}))
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() {
		_ = (&tailnetagent.Server{
			Dir:         tailnetagent.Dir(gitDir),
			IdleTimeout: time.Hour,
			Password:    "secret",
			Dial:        dial,
		}).Run(ctx)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := tailnetagent.ProxyURL(gitDir); ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("test tailnet agent did not become ready")
}

func importerGitDir(t *testing.T, repo string) string {
	t.Helper()
	gitDir := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "--git-dir"))
	if filepath.IsAbs(gitDir) {
		return gitDir
	}
	return filepath.Join(repo, gitDir)
}
