package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

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
