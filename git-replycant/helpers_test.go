package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestMain pins a git identity for every git subprocess these tests spawn.
// Configuring the clone enables diff.replycant-crypt.cachetextconv, and git
// writes that cache through notes, so even a read-only `git diff` needs a
// committer. Developer machines usually supply a fallback identity, while CI
// runners do not, so tests must not depend on ambient git configuration.
func TestMain(m *testing.M) {
	identity := map[string]string{
		"GIT_AUTHOR_NAME":     "test",
		"GIT_AUTHOR_EMAIL":    "test@example.com",
		"GIT_COMMITTER_NAME":  "test",
		"GIT_COMMITTER_EMAIL": "test@example.com",
	}
	for key, value := range identity {
		if err := os.Setenv(key, value); err != nil {
			panic(err)
		}
	}
	os.Exit(m.Run())
}

// testInitRepo creates an isolated git repository so tests can exercise repo-scoped behavior safely.
func testInitRepo(t *testing.T) string {
	t.Helper()
	repoDir := t.TempDir()
	testRunGit(t, "", "init", repoDir)
	return repoDir
}

// testRunGit executes git commands and fails tests immediately with command output for easier debugging.
func testRunGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "git %v failed: %s", args, string(out))
	return string(out)
}

// testWriteFile writes fixture files while guaranteeing parent directories exist.
func testWriteFile(t *testing.T, path string, content []byte, mode os.FileMode) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, content, mode))
}
