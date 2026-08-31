package main

import (
	"crypto/sha256"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSanitizeFilterError verifies protocol error payloads stay one-line and bounded.
func TestSanitizeFilterError(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "a b c", sanitizeFilterError("a\nb\rc"))
	assert.Equal(t, "short", sanitizeFilterError("short"))

	long := strings.Repeat("x", 600)
	sanitized := sanitizeFilterError(long)
	assert.Len(t, sanitized, 503)
	assert.True(t, strings.HasSuffix(sanitized, "..."))
}

// TestParseEpochFromPath validates epoch extraction from canonical encryption epoch paths.
func TestParseEpochFromPath(t *testing.T) {
	t.Parallel()
	tests := []struct {
		path  string
		want  int
		valid bool
	}{
		{path: "encryption/epochs/1.age", want: 1, valid: true},
		{path: "encryption/epochs/42.age", want: 42, valid: true},
		{path: "encryption/epochs/0.age", valid: false},
		{path: "encryption/epochs/abc.age", valid: false},
		{path: "other/path.age", valid: false},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.path, func(t *testing.T) {
			t.Parallel()
			got, ok := parseEpochFromPath(tt.path)
			assert.Equal(t, tt.valid, ok)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestContainsPacketLine ensures handshake helpers match trimmed packet lines accurately.
func TestContainsPacketLine(t *testing.T) {
	t.Parallel()
	lines := [][]byte{[]byte("git-filter-client\n"), []byte("version=2\n")}
	assert.True(t, containsPacketLine(lines, "git-filter-client"))
	assert.False(t, containsPacketLine(lines, "capability=clean"))
}

// TestReadFilterInput verifies one-shot filters accept file-path input and reject extra arguments.
func TestReadFilterInput(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	path := filepath.Join(tmp, "manifest.yaml")
	testWriteFile(t, path, []byte("hello"), 0o644)

	raw, err := readFilterInput([]string{path})
	require.NoError(t, err)
	assert.Equal(t, []byte("hello"), raw)

	_, err = readFilterInput([]string{"a", "b"})
	require.Error(t, err)
}

// testFilterRuntime builds a FilterRuntime with a pre-loaded KEK cache for unit tests
// that need index matching without full identity/age setup.
func testFilterRuntime(repoDir string, kek []byte, epoch int) *FilterRuntime {
	return &FilterRuntime{
		repoRoot:            repoDir,
		kekCache:            map[int][]byte{epoch: kek},
		indexHashCache:      make(map[string][32]byte),
		indexEncryptedCache: make(map[string][]byte),
	}
}

// TestMatchesIndexManifest verifies hash-based no-op clean detection for staged encrypted manifests.
func TestMatchesIndexManifest(t *testing.T) {
	t.Parallel()
	kek := []byte("0123456789abcdef0123456789abcdef")
	epoch := 1
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")

	encrypted, err := gitcrypt.EncryptManifestEnvelope(plaintext, kek, epoch)
	require.NoError(t, err)

	repoDir := testInitRepo(t)
	manifestPath := filepath.Join(repoDir, "manifests", "test.yaml")
	testWriteFile(t, manifestPath, encrypted, 0o644)
	testRunGit(t, repoDir, "add", "manifests/test.yaml")

	rt := testFilterRuntime(repoDir, kek, epoch)

	enc, matched, err := rt.matchesIndexManifest("manifests/test.yaml", plaintext)
	require.NoError(t, err)
	assert.True(t, matched)
	assert.Equal(t, encrypted, enc)

	different := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Modified\n")
	enc, matched, err = rt.matchesIndexManifest("manifests/test.yaml", different)
	require.NoError(t, err)
	assert.False(t, matched)
	assert.Equal(t, encrypted, enc)
}

// TestMatchesIndexManifestCacheHit verifies repeated calls use the cached hash without re-reading git.
func TestMatchesIndexManifestCacheHit(t *testing.T) {
	t.Parallel()
	kek := []byte("0123456789abcdef0123456789abcdef")
	epoch := 1
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: CacheTest\n")

	encrypted, err := gitcrypt.EncryptManifestEnvelope(plaintext, kek, epoch)
	require.NoError(t, err)

	repoDir := testInitRepo(t)
	manifestPath := filepath.Join(repoDir, "manifests", "cached.yaml")
	testWriteFile(t, manifestPath, encrypted, 0o644)
	testRunGit(t, repoDir, "add", "manifests/cached.yaml")

	rt := testFilterRuntime(repoDir, kek, epoch)

	_, matched, err := rt.matchesIndexManifest("manifests/cached.yaml", plaintext)
	require.NoError(t, err)
	assert.True(t, matched)

	expectedHash := sha256.Sum256(plaintext)
	cachedHash, ok := rt.indexHashCache["manifests/cached.yaml"]
	require.True(t, ok)
	assert.Equal(t, expectedHash, cachedHash)

	_, matched, err = rt.matchesIndexManifest("manifests/cached.yaml", plaintext)
	require.NoError(t, err)
	assert.True(t, matched)
}

// TestMatchesIndexManifestMissingPath returns no match for paths absent from the git index.
func TestMatchesIndexManifestMissingPath(t *testing.T) {
	t.Parallel()
	repoDir := testInitRepo(t)
	rt := testFilterRuntime(repoDir, []byte("0123456789abcdef0123456789abcdef"), 1)

	_, matched, err := rt.matchesIndexManifest("nonexistent.yaml", []byte("anything"))
	require.NoError(t, err)
	assert.False(t, matched)
}

// TestMatchesIndexManifestPlaintextStaged returns no match when staged file is not encrypted.
func TestMatchesIndexManifestPlaintextStaged(t *testing.T) {
	t.Parallel()
	repoDir := testInitRepo(t)
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	manifestPath := filepath.Join(repoDir, "manifests", "plain.yaml")
	testWriteFile(t, manifestPath, plaintext, 0o644)
	testRunGit(t, repoDir, "add", "manifests/plain.yaml")

	rt := testFilterRuntime(repoDir, []byte("0123456789abcdef0123456789abcdef"), 1)

	_, matched, err := rt.matchesIndexManifest("manifests/plain.yaml", plaintext)
	require.NoError(t, err)
	assert.False(t, matched)
}

// TestRequireFilterDatabaseVersion accepts a missing marker as version
// 0 and refuses any other unsupported integer.
func TestRequireFilterDatabaseVersion(t *testing.T) {
	t.Parallel()
	repoDir := testInitRepo(t)
	rt := testFilterRuntime(repoDir, []byte("0123456789abcdef0123456789abcdef"), 1)
	require.NoError(t, requireFilterDatabaseVersion(rt))

	testWriteFile(t, filepath.Join(repoDir, "gitdb", "version"), []byte("1\n"), 0o644)
	require.NoError(t, requireFilterDatabaseVersion(rt))

	testWriteFile(t, filepath.Join(repoDir, "gitdb", "version"), []byte("2\n"), 0o644)
	err := requireFilterDatabaseVersion(rt)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unsupported gitdb database version 2")
}

// TestSmudgeRejectsPlaintextManifest ensures a hostile server cannot strip the
// envelope and have clients accept attacker-controlled YAML as a valid manifest.
func TestSmudgeRejectsPlaintextManifest(t *testing.T) {
	t.Parallel()
	rt := testFilterRuntime(t.TempDir(), []byte("0123456789abcdef0123456789abcdef"), 1)
	_, err := rt.Smudge([]byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "plaintext manifest rejected")
}

// TestSmudgeDecryptsEncryptedEnvelope verifies the happy path still decrypts
// after plaintext passthrough was removed.
func TestSmudgeDecryptsEncryptedEnvelope(t *testing.T) {
	t.Parallel()
	kek := []byte("0123456789abcdef0123456789abcdef")
	epoch := 1
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	encrypted, err := gitcrypt.EncryptManifestEnvelope(plaintext, kek, epoch)
	require.NoError(t, err)

	rt := testFilterRuntime(t.TempDir(), kek, epoch)
	got, err := rt.Smudge(encrypted)
	require.NoError(t, err)
	assert.Equal(t, plaintext, got)
}

// TestRunSmudgeOnceTextconvPassesPlaintext keeps git diff working: textconv
// feeds already-smudged worktree plaintext via a path argument.
func TestRunSmudgeOnceTextconvPassesPlaintext(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "manifest.yaml")
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	testWriteFile(t, path, plaintext, 0o644)

	stdoutReader, stdoutWriter, err := os.Pipe()
	require.NoError(t, err)
	originalStdout := os.Stdout
	os.Stdout = stdoutWriter
	runErr := RunSmudgeOnce([]string{path})
	os.Stdout = originalStdout
	require.NoError(t, stdoutWriter.Close())
	stdout, readErr := io.ReadAll(stdoutReader)
	require.NoError(t, readErr)
	require.NoError(t, stdoutReader.Close())
	require.NoError(t, runErr)
	assert.Equal(t, plaintext, stdout)
}
