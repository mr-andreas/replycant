package gittest

import (
	"os/exec"
	"testing"
)

// DisableAutoMaintenance stops git from detaching a background maintenance
// process after pushes into this repository. That process outlives the push
// and can write into objects/ while t.TempDir cleanup is deleting the tree,
// which fails the test with "directory not empty".
func DisableAutoMaintenance(t testing.TB, gitDir string) {
	t.Helper()
	configs := [][2]string{
		{"receive.autogc", "false"},
		{"gc.auto", "0"},
		{"maintenance.auto", "false"},
	}
	for _, pair := range configs {
		cmd := exec.Command("git", "--git-dir="+gitDir, "config", pair[0], pair[1])
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git config %s=%s failed: %v: %s", pair[0], pair[1], err, string(out))
		}
	}
}
