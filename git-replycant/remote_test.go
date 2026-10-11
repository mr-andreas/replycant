package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/mr-andreas/replycant/pkg/tailnetagent"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Git chooses the transport from argv[0]. A path prefix must not stop the
// installed binary from being recognized as the helper.
func TestIsRemoteHelper(t *testing.T) {
	t.Parallel()
	assert.True(t, isRemoteHelper("/usr/local/bin/git-remote-replycant"))
	assert.False(t, isRemoteHelper("/usr/local/bin/git-replycant"))
}

// The proxy credential has to reach git without showing up in argv, and
// without discarding the -c options git already put in the environment.
func TestWithHTTPProxyAppendsConfig(t *testing.T) {
	t.Parallel()
	env := withHTTPProxy([]string{
		"PATH=/usr/bin",
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http.sslCAInfo",
		"GIT_CONFIG_VALUE_0=/tmp/ca.pem",
	}, "http://replycant:secret@127.0.0.1:9")

	assert.Contains(t, env, "PATH=/usr/bin")
	assert.Contains(t, env, "GIT_CONFIG_COUNT=2")
	assert.Contains(t, env, "GIT_CONFIG_KEY_0=http.sslCAInfo")
	assert.Contains(t, env, "GIT_CONFIG_KEY_1=http.proxy")
	assert.Contains(t, env, "GIT_CONFIG_VALUE_1=http://replycant:secret@127.0.0.1:9")
	assert.NotContains(t, env, "GIT_CONFIG_COUNT=1")
}

// A direct URL keeps the helper prefix on the remote name. git remote-https
// has to see the plain https URL or it will try to launch this helper again.
func TestStripHelperPrefix(t *testing.T) {
	t.Parallel()
	got := stripHelperPrefix([]string{
		"replycant::https://gitd.replycant.internal:8443",
		"https://gitd.replycant.internal:8443",
	})
	assert.Equal(t, []string{
		"https://gitd.replycant.internal:8443",
		"https://gitd.replycant.internal:8443",
	}, got)
}

// Repositories cloned before the tailnet, or copied without their node
// state, cannot fall back to dialing gitd directly.
func TestRemoteHelperRefusesRepoWithoutTailnet(t *testing.T) {
	gitDir := t.TempDir()
	t.Setenv("GIT_DIR", gitDir)
	err := runRemoteHelper([]string{"origin", "https://gitd.replycant.internal:8443"})
	require.Error(t, err)
	assert.ErrorIs(t, err, tailnetagent.ErrNotConfigured)
}

// The helper starts the shared agent and then hands the session to git's
// https transport, with the proxy visible only in the environment.
func TestRemoteHelperUsesAgentProxy(t *testing.T) {
	gitDir := t.TempDir()
	writeTailnetFiles(t, gitDir)
	t.Setenv("GIT_DIR", gitDir)

	restore := stubRemoteHelper(
		func(context.Context, string, tailnetagent.StartConfig, tailnetagent.Spawner) (string, error) {
			return "http://replycant:secret@127.0.0.1:9", nil
		},
		func(env []string, args ...string) error {
			assert.Equal(t, []string{"origin", "https://gitd.replycant.internal:8443"}, args)
			assert.Contains(t, env, "GIT_CONFIG_KEY_0=http.proxy")
			assert.Contains(t, env, "GIT_CONFIG_VALUE_0=http://replycant:secret@127.0.0.1:9")
			return nil
		},
	)
	t.Cleanup(restore)

	require.NoError(t, runRemoteHelper([]string{"origin", "replycant::https://gitd.replycant.internal:8443"}))
}

func TestRemoteHelperReportsAgentFailure(t *testing.T) {
	gitDir := t.TempDir()
	writeTailnetFiles(t, gitDir)
	t.Setenv("GIT_DIR", gitDir)

	restore := stubRemoteHelper(
		func(context.Context, string, tailnetagent.StartConfig, tailnetagent.Spawner) (string, error) {
			return "", errors.New("join failed")
		},
		func([]string, ...string) error {
			t.Fatal("https transport should not run when the agent failed")
			return nil
		},
	)
	t.Cleanup(restore)

	err := runRemoteHelper([]string{"origin", "https://gitd.replycant.internal:8443"})
	require.EqualError(t, err, "join failed")
}

func stubRemoteHelper(
	ensure func(context.Context, string, tailnetagent.StartConfig, tailnetagent.Spawner) (string, error),
	run func([]string, ...string) error,
) func() {
	prevEnsure := ensureTailnetAgent
	prevExec := execRemoteHTTPS
	ensureTailnetAgent = ensure
	execRemoteHTTPS = run
	return func() {
		ensureTailnetAgent = prevEnsure
		execRemoteHTTPS = prevExec
	}
}

func writeTailnetFiles(t *testing.T, gitDir string) {
	t.Helper()
	require.NoError(t, tailnetagent.SaveConfig(gitDir, tailnetagent.PersistedConfig{
		HeadscaleAddr:       "headscale.example:443",
		HeadscaleServerName: "headscale.example",
		Hostname:            "cli",
	}))
	replycantDir := filepath.Join(gitDir, "replycant")
	for _, name := range []string{"ca.pem", "client-cert.pem", "client-key.pem"} {
		require.NoError(t, os.WriteFile(filepath.Join(replycantDir, name), []byte("pem"), 0o600))
	}
}
