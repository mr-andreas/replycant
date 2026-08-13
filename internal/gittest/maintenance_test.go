package gittest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestDisableAutoMaintenanceStopsPostPushMaintenance pins the configs that
// keep git from detaching a background maintenance process after a push.
// That process outlives the push and can write into objects/ while
// t.TempDir cleanup deletes the tree, failing tests with "directory not
// empty".
func TestDisableAutoMaintenanceStopsPostPushMaintenance(t *testing.T) {
	tempDir := t.TempDir()
	bareRepo := filepath.Join(tempDir, "repo.git")
	workDir := filepath.Join(tempDir, "work")

	runGit(t, "", "init", "--initial-branch=main", "--bare", bareRepo)
	DisableAutoMaintenance(t, bareRepo)

	require.Equal(t, "false", gitConfigGet(t, bareRepo, "receive.autogc"))
	require.Equal(t, "0", gitConfigGet(t, bareRepo, "gc.auto"))
	require.Equal(t, "false", gitConfigGet(t, bareRepo, "maintenance.auto"))

	runGit(t, "", "init", "--initial-branch=main", workDir)
	require.NoError(t, os.WriteFile(filepath.Join(workDir, "seed.txt"), []byte("seed\n"), 0o644))
	runGit(t, workDir, "add", ".")
	runGit(
		t,
		workDir,
		"-c", "user.name=test",
		"-c", "user.email=test@example.com",
		"commit",
		"-m",
		"seed",
	)
	runGit(t, workDir, "remote", "add", "origin", "file://"+bareRepo)

	trace := pushWithTrace(t, workDir)
	require.NotContains(t, trace, "maintenance run --auto")
	require.NotContains(t, trace, "gc --auto")
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "git %v failed: %s", args, string(out))
	return string(out)
}

func gitConfigGet(t *testing.T, gitDir string, key string) string {
	t.Helper()
	return strings.TrimSpace(runGit(t, "", "--git-dir="+gitDir, "config", "--get", key))
}

func pushWithTrace(t *testing.T, workDir string) string {
	t.Helper()
	cmd := exec.Command("git", "push", "-u", "origin", "main")
	cmd.Dir = workDir
	cmd.Env = append(os.Environ(), "GIT_TRACE=1")
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "git push failed: %s", string(out))
	return string(out)
}
