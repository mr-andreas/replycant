package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/require"
)

// runGitForTest executes git commands and fails the test with command output on error.
func runGitForTest(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return strings.TrimSpace(string(runGitBytesForTest(t, dir, args...)))
}

// runGitBytesForTest executes git commands and returns raw bytes for binary payload assertions.
func runGitBytesForTest(t *testing.T, dir string, args ...string) []byte {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "git %v failed: %s", args, string(out))
	return out
}

// TestSeedRepositoryAppendMediaOnly verifies media seeding appends encrypted history in balanced commits.
func TestSeedRepositoryAppendMediaOnly(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	bareRepo := filepath.Join(tempDir, "repo.git")
	outputDir := filepath.Join(tempDir, "identity")
	runGitForTest(t, "", "init", "--initial-branch=main", "--bare", bareRepo)

	err := seedRepository(seederConfig{
		bareRepo:    bareRepo,
		outputDir:   outputDir,
		deviceSpace: "e2e-device",
	})
	require.NoError(t, err)

	err = seedRepository(seederConfig{
		bareRepo:     bareRepo,
		outputDir:    outputDir,
		deviceSpace:  "e2e-device",
		mediaCount:   1000,
		commitCount:  10,
		addMediaOnly: true,
	})
	require.NoError(t, err)

	commitCount := runGitForTest(t, "", "--git-dir="+bareRepo, "rev-list", "--count", "main")
	require.Equal(t, "11", commitCount)

	tree := runGitForTest(t, "", "--git-dir="+bareRepo, "ls-tree", "-r", "--name-only", "main")
	lines := strings.Split(tree, "\n")
	originalCount := 0
	thumbnailCount := 0
	for _, line := range lines {
		if strings.Contains(line, "/Original/") {
			originalCount += 1
		}
		if strings.Contains(line, "/ThumbnailSet/") {
			thumbnailCount += 1
		}
	}
	require.Equal(t, 1000, originalCount)
	require.Equal(t, 1000, thumbnailCount)
	require.Contains(
		t,
		tree,
		"manifests/e2e-device/media.replycant.com/v1alpha1/Original/im/g-/000000.yaml",
	)
}

// TestSeedRepositoryEncryptedManifest verifies seeded manifest payloads decrypt into protocol YAML.
func TestSeedRepositoryEncryptedManifest(t *testing.T) {
	t.Parallel()
	tempDir := t.TempDir()
	bareRepo := filepath.Join(tempDir, "repo.git")
	outputDir := filepath.Join(tempDir, "identity")
	runGitForTest(t, "", "init", "--initial-branch=main", "--bare", bareRepo)

	err := seedRepository(seederConfig{
		bareRepo:    bareRepo,
		outputDir:   outputDir,
		deviceSpace: "e2e-device",
	})
	require.NoError(t, err)
	err = seedRepository(seederConfig{
		bareRepo:     bareRepo,
		outputDir:    outputDir,
		deviceSpace:  "e2e-device",
		mediaCount:   10,
		commitCount:  2,
		addMediaOnly: true,
	})
	require.NoError(t, err)

	identityRaw, err := os.ReadFile(filepath.Join(outputDir, "identity.json"))
	require.NoError(t, err)
	var identity gitcrypt.Identity
	require.NoError(t, json.Unmarshal(identityRaw, &identity))

	currentRaw := runGitForTest(t, "", "--git-dir="+bareRepo, "show", "main:encryption/current")
	epoch, err := gitcrypt.ParseCurrentEpoch([]byte(currentRaw))
	require.NoError(t, err)
	envelope := runGitForTest(t, "", "--git-dir="+bareRepo, "show", "main:encryption/epochs/1.age")
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope([]byte(envelope), identity.AgePrivateKeyBase64)
	require.NoError(t, err)

	blob := runGitBytesForTest(
		t,
		"",
		"--git-dir="+bareRepo,
		"show",
		"main:manifests/e2e-device/media.replycant.com/v1alpha1/Original/im/g-/000000.yaml",
	)
	plaintext, parsedEpoch, err := gitcrypt.DecodeManifestEnvelope(blob, kek)
	require.NoError(t, err)
	require.Equal(t, epoch, parsedEpoch)
	require.Contains(t, string(plaintext), "kind: Original")
	require.Contains(t, string(plaintext), "name: img-000000")
}

// TestValidateConfigRejectsInvalidCommitSplit keeps seeding failures explicit for bad CLI input.
func TestValidateConfigRejectsInvalidCommitSplit(t *testing.T) {
	t.Parallel()
	err := validateConfig(seederConfig{
		bareRepo:    "/tmp/repo.git",
		outputDir:   "/tmp/out",
		deviceSpace: "e2e-device",
		mediaCount:  5,
		commitCount: 10,
	})
	require.ErrorContains(t, err, "--commit-count cannot exceed --media-count")
}
