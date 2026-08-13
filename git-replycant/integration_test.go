package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/cgi"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/mr-andreas/replycant/internal/gittest"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

// testCloneFixture keeps reusable integration fixture state for clone-flow test cases.
type testCloneFixture struct {
	repoDir       string
	local         gitcrypt.LocalIdentity
	options       CloneOptions
	repoURL       string
	lfsURL        string
	caPEM         string
	plainManifest []byte
	server        *httptest.Server
}

// testLFSCloneFixture extends clone fixtures with mock LFS storage and known binary plaintext bytes.
type testLFSCloneFixture struct {
	testCloneFixture
	plainBinary []byte
	lfsStoreDir string
	objectOID   string
	objectBytes []byte
}

// prepareClonedRepo performs the full clone preparation sequence so assertions can focus on behavior outcomes.
func prepareClonedRepo(t *testing.T, initiallyAuthorized bool) testCloneFixture {
	t.Helper()
	fixture := setupCloneFixture(t, initiallyAuthorized)

	binDir := t.TempDir()
	buildGitReplycantBinary(t, filepath.Join(binDir, "git-replycant"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	repoDir := fixture.repoDir
	local := fixture.local
	repoURL := fixture.repoURL
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)

	require.NoError(t, PollAuthorization(context.Background(), repoURL, local, caFilePath))
	require.NoError(t, FetchRepository(context.Background(), repoDir, local, caFilePath, 0))
	require.NoError(t, ConfigureRepository(repoDir, fixture.lfsURL, local, caFilePath))
	branch, err := ResolveDefaultRemoteBranch(repoDir)
	require.NoError(t, err)
	require.NoError(t, CheckoutTrackingBranch(context.Background(), repoDir, branch))
	return fixture
}

// TestFullCloneFlow verifies init->identity->poll->fetch->configure->checkout works with a mocked mTLS git server.
func TestFullCloneFlow(t *testing.T) {
	fixture := prepareClonedRepo(t, true)

	repoDir := fixture.repoDir
	manifestGitPath := "manifests/test-device/test.yaml"
	manifestPath := filepath.Join(repoDir, filepath.FromSlash(manifestGitPath))

	assert.FileExists(t, filepath.Join(repoDir, ".git", "replycant", "identity.json"))
	assert.FileExists(t, filepath.Join(repoDir, ".git", "replycant", "client-key.pem"))
	assert.FileExists(t, filepath.Join(repoDir, ".git", "replycant", "client-cert.pem"))
	assert.FileExists(t, filepath.Join(repoDir, ".git", "replycant", "ca.pem"))

	assert.Equal(t, filepath.Join(repoDir, ".git", "replycant", "ca.pem"), strings.TrimSpace(testRunGit(t, repoDir, "config", "--local", "--get", "http.sslCAInfo")))
	assert.Equal(t, "git-replycant filter-process", strings.TrimSpace(testRunGit(t, repoDir, "config", "--local", "--get", "filter.replycant-crypt.process")))
	assert.Equal(t, "git-replycant smudge", strings.TrimSpace(testRunGit(t, repoDir, "config", "--local", "--get", "diff.replycant-crypt.textconv")))

	attrs, err := os.ReadFile(filepath.Join(repoDir, ".git", "info", "attributes"))
	require.NoError(t, err)
	assert.Contains(t, string(attrs), "manifests/** filter=replycant-crypt")
	assert.Contains(t, string(attrs), "manifests/** diff=replycant-crypt")
	assert.FileExists(t, filepath.Join(repoDir, "encryption", "current"))
	assert.FileExists(t, manifestPath)

	raw, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	assert.Equal(t, fixture.plainManifest, raw)
	assert.False(t, gitcrypt.IsEncryptedManifest(raw))

	indexBlob := testRunGit(t, repoDir, "show", ":"+manifestGitPath)
	assert.True(t, gitcrypt.IsEncryptedManifest([]byte(indexBlob)))
}

// TestPollAuthorizationRetries verifies 401 responses are retried until authorization becomes available.
func TestPollAuthorizationRetries(t *testing.T) {
	fixture := setupCloneFixture(t, false)
	defer fixture.server.Close()

	repoURL := fixture.repoURL
	local := fixture.local
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		done <- PollAuthorization(ctx, repoURL, local, caFilePath)
	}()

	time.Sleep(500 * time.Millisecond)
	setServerAuthorized(t, fixture.server, true)

	select {
	case err := <-done:
		require.NoError(t, err)
	case <-ctx.Done():
		t.Fatalf("poll authorization did not finish in time: %v", ctx.Err())
	}
}

// TestSmudgeDecryptsAfterClone verifies checkout writes plaintext manifests via configured smudge filter.
func TestSmudgeDecryptsAfterClone(t *testing.T) {
	fixture := prepareClonedRepo(t, true)

	repoDir := fixture.repoDir
	raw, err := os.ReadFile(filepath.Join(repoDir, "manifests", "test-device", "test.yaml"))
	require.NoError(t, err)
	assert.Equal(t, fixture.plainManifest, raw)
	assert.False(t, gitcrypt.IsEncryptedManifest(raw))
	assert.Contains(t, string(raw), "apiVersion:")
}

// TestCleanFilterIdempotent verifies unchanged plaintext does not produce noisy git status output.
func TestCleanFilterIdempotent(t *testing.T) {
	fixture := prepareClonedRepo(t, true)

	repoDir := fixture.repoDir
	manifestGitPath := "manifests/test-device/test.yaml"
	manifestPath := filepath.Join(repoDir, filepath.FromSlash(manifestGitPath))

	status := strings.TrimSpace(testRunGit(t, repoDir, "status", "--porcelain"))
	assert.Empty(t, status)

	raw, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	assert.Equal(t, fixture.plainManifest, raw)

	modified := append([]byte{}, fixture.plainManifest...)
	modified = append(modified, []byte("# modified\n")...)
	testWriteFile(t, manifestPath, modified, 0o644)
	testRunGit(t, repoDir, "add", manifestGitPath)
	testRunGit(t, repoDir, "checkout", "HEAD", "--", manifestGitPath)

	restored, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	assert.Equal(t, fixture.plainManifest, restored)
}

// TestManifestRoundtripThroughGit validates edit/add/commit/read behavior across clean and smudge filters.
func TestManifestRoundtripThroughGit(t *testing.T) {
	fixture := prepareClonedRepo(t, true)

	repoDir := fixture.repoDir
	manifestGitPath := "manifests/test-device/test.yaml"
	manifestPath := filepath.Join(repoDir, filepath.FromSlash(manifestGitPath))

	originalRaw, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	assert.Equal(t, fixture.plainManifest, originalRaw)
	assert.False(t, gitcrypt.IsEncryptedManifest(originalRaw))

	modified := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\nmetadata:\n  note: changed\n")
	testWriteFile(t, manifestPath, modified, 0o644)
	testRunGit(t, repoDir, "add", manifestGitPath)
	testRunGit(t, repoDir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "modify manifest")

	headBlob := testRunGit(t, repoDir, "show", "HEAD:"+manifestGitPath)
	assert.True(t, gitcrypt.IsEncryptedManifest([]byte(headBlob)))

	workingRaw, err := os.ReadFile(manifestPath)
	require.NoError(t, err)
	assert.Equal(t, modified, workingRaw)
	assert.False(t, gitcrypt.IsEncryptedManifest(workingRaw))

	status := strings.TrimSpace(testRunGit(t, repoDir, "status", "--porcelain"))
	assert.Empty(t, status)
}

// TestTextconvShowsPlaintext verifies git diff uses textconv output instead of binary-only encrypted comparisons.
func TestTextconvShowsPlaintext(t *testing.T) {
	fixture := prepareClonedRepo(t, true)

	repoDir := fixture.repoDir
	manifestGitPath := "manifests/test-device/test.yaml"
	manifestPath := filepath.Join(repoDir, filepath.FromSlash(manifestGitPath))

	modified := append([]byte{}, fixture.plainManifest...)
	modified = append(modified, []byte("metadata:\n  annotation: diff-check\n")...)
	testWriteFile(t, manifestPath, modified, 0o644)

	diff := testRunGit(t, repoDir, "diff", "--", manifestGitPath)
	assert.Contains(t, diff, "apiVersion:")
	assert.Contains(t, diff, "annotation: diff-check")
	assert.NotContains(t, diff, "Binary files differ")
	assert.NotContains(t, diff, "REPLYCANT-ENC-V1")
}

// TestLFSSmudgeDecryptsAfterClone verifies binary pointers are resolved and decrypted during checkout.
func TestLFSSmudgeDecryptsAfterClone(t *testing.T) {
	fixture := prepareLFSClonedRepo(t)

	raw, err := os.ReadFile(filepath.Join(fixture.repoDir, "binary", "test.bin"))
	require.NoError(t, err)
	assert.Equal(t, fixture.plainBinary, raw)
	assert.False(t, gitcrypt.IsLFSPointer(raw))

	indexPointer := testRunGit(t, fixture.repoDir, "show", ":binary/test.bin")
	assert.True(t, gitcrypt.IsLFSPointer([]byte(indexPointer)))
	assert.Contains(t, indexPointer, "x-replycant-kek-epoch")

	status := strings.TrimSpace(testRunGit(t, fixture.repoDir, "status", "--porcelain", "--", "binary/"))
	assert.NotContains(t, status, "binary/test.bin", "expected no binary files to appear modified immediately after checkout")
}

// TestLFSCleanRoundtrip verifies add/checkout paths preserve decrypted working bytes while uploading encrypted objects.
func TestLFSCleanRoundtrip(t *testing.T) {
	fixture := prepareLFSClonedRepo(t)
	initialPointer := testRunGit(t, fixture.repoDir, "show", ":binary/test.bin")
	initialParsed, err := gitcrypt.ParseLFSPointer([]byte(initialPointer))
	require.NoError(t, err)

	modified := append([]byte{}, fixture.plainBinary...)
	modified = append(modified, []byte("-changed")...)
	testWriteFile(t, filepath.Join(fixture.repoDir, "binary", "test.bin"), modified, 0o644)
	testRunGit(t, fixture.repoDir, "add", "binary/test.bin")

	indexPointer := testRunGit(t, fixture.repoDir, "show", ":binary/test.bin")
	parsed, err := gitcrypt.ParseLFSPointer([]byte(indexPointer))
	require.NoError(t, err)
	assert.Equal(t, 1, parsed.KekEpoch)
	assert.NotEmpty(t, parsed.WrappedDEK)
	assert.NotEqual(t, initialParsed.OID, parsed.OID)

	uploadedEncrypted, ok := readFakeLFSObject(fixture.lfsStoreDir, parsed.OID)
	require.True(t, ok, "expected uploaded encrypted object in fake LFS store")
	assert.NotEqual(t, string(modified), string(uploadedEncrypted))

	epochEnvelope, err := os.ReadFile(filepath.Join(fixture.repoDir, "encryption", "epochs", "1.age"))
	require.NoError(t, err)
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(epochEnvelope, fixture.local.Identity.AgePrivateKeyBase64)
	require.NoError(t, err)
	dek, err := gitcrypt.UnwrapDEK(parsed.WrappedDEK, kek, parsed.KekEpoch)
	require.NoError(t, err)
	decrypted, err := gitcrypt.DecryptChunked(uploadedEncrypted, dek)
	require.NoError(t, err)
	assert.Equal(t, modified, decrypted)

	testRunGit(t, fixture.repoDir, "checkout", "HEAD", "--", "binary/test.bin")
	restored, err := os.ReadFile(filepath.Join(fixture.repoDir, "binary", "test.bin"))
	require.NoError(t, err)
	assert.Equal(t, fixture.plainBinary, restored)
}

// TestLFSPushUploadsObjectsWithPrePushHook verifies git push uploads Replycant pointer objects via custom hook.
func TestLFSPushUploadsObjectsWithPrePushHook(t *testing.T) {
	fixture := setupLFSCloneFixture(t)
	t.Cleanup(fixture.server.Close)

	binDir := t.TempDir()
	buildGitReplycantBinary(t, filepath.Join(binDir, "git-replycant"))
	buildFakeGitLFSIntegrationBinary(t, filepath.Join(binDir, "git-lfs"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	repoDir := fixture.repoDir
	localStoreDir := filepath.Join(repoDir, ".git", "lfs", "objects")
	require.NoError(t, os.MkdirAll(localStoreDir, 0o755))
	t.Setenv("REPLYCANT_FAKE_LFS_STORE", localStoreDir)
	writeFakeLFSObject(t, localStoreDir, fixture.objectOID, fixture.objectBytes)

	remoteStoreDir := filepath.Join(t.TempDir(), "remote-lfs-store")
	require.NoError(t, os.MkdirAll(remoteStoreDir, 0o755))
	writeFakeLFSObject(t, remoteStoreDir, fixture.objectOID, fixture.objectBytes)
	lfsServer := startFakeLFSBatchServer(t, remoteStoreDir)
	t.Cleanup(lfsServer.Close)

	local := fixture.local
	repoURL := fixture.repoURL
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)
	lfsURL := lfsServer.URL

	require.NoError(t, PollAuthorization(context.Background(), repoURL, local, caFilePath))
	require.NoError(t, FetchRepository(context.Background(), repoDir, local, caFilePath, 0))
	require.NoError(t, ConfigureRepository(repoDir, lfsURL, local, caFilePath))
	branch, err := ResolveDefaultRemoteBranch(repoDir)
	require.NoError(t, err)
	require.NoError(t, PreExtractEncryptionFiles(context.Background(), repoDir, branch))
	if err := CheckoutTrackingBranch(context.Background(), repoDir, branch); err != nil {
		if strings.Contains(err.Error(), "smudge filter replycant-crypt failed") {
			t.Skipf("environment does not support LFS filter-process integration: %v", err)
		}
		require.NoError(t, err)
	}

	modified := append([]byte{}, fixture.plainBinary...)
	modified = append(modified, []byte("-push-upload")...)
	testWriteFile(t, filepath.Join(repoDir, "binary", "test.bin"), modified, 0o644)
	testRunGit(t, repoDir, "add", "binary/test.bin")
	testRunGit(t, repoDir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "update binary")

	indexPointer := testRunGit(t, repoDir, "show", ":binary/test.bin")
	parsed, err := gitcrypt.ParseLFSPointer([]byte(indexPointer))
	require.NoError(t, err)
	_, existsBefore := readFakeLFSObject(remoteStoreDir, parsed.OID)
	assert.False(t, existsBefore)

	testRunGit(t, repoDir, "push", "origin", "HEAD")

	uploaded, existsAfter := readFakeLFSObject(remoteStoreDir, parsed.OID)
	require.True(t, existsAfter, "expected pre-push hook to upload object to remote LFS store")
	assert.NotEmpty(t, uploaded)

	t.Setenv("REPLYCANT_FAKE_LFS_STORE", remoteStoreDir)
	secondOptions := CloneOptions{
		ServerURL: fixture.options.ServerURL,
		Directory: filepath.Join(t.TempDir(), "clone-target-2"),
	}
	secondRepoDir, err := InitializeRepository(context.Background(), secondOptions.Directory, repoURL, secondOptions.ServerURL, false)
	require.NoError(t, err)
	secondConfigDir := filepath.Join(secondRepoDir, ".git", "replycant")
	require.NoError(t, copyTestDirectory(local.ConfigDirectory, secondConfigDir))
	secondLocal, _, err := gitcrypt.EnsureLocalIdentity(secondRepoDir, "integration-test-device-2")
	require.NoError(t, err)
	secondCAPath := filepath.Join(secondLocal.ConfigDirectory, "ca.pem")
	require.NoError(t, PollAuthorization(context.Background(), repoURL, secondLocal, secondCAPath))
	require.NoError(t, FetchRepository(context.Background(), secondRepoDir, secondLocal, secondCAPath, 0))
	require.NoError(t, ConfigureRepository(secondRepoDir, lfsURL, secondLocal, secondCAPath))
	secondBranch, err := ResolveDefaultRemoteBranch(secondRepoDir)
	require.NoError(t, err)
	require.NoError(t, PreExtractEncryptionFiles(context.Background(), secondRepoDir, secondBranch))
	require.NoError(t, CheckoutTrackingBranch(context.Background(), secondRepoDir, secondBranch))
	reclonedBinary, err := os.ReadFile(filepath.Join(secondRepoDir, "binary", "test.bin"))
	require.NoError(t, err)
	assert.Equal(t, modified, reclonedBinary)
}

// TestLFSCheckoutStreamsProgress ensures checkout surfaces LFS download progress while large objects are smudged.
func TestLFSCheckoutStreamsProgress(t *testing.T) {
	fixture := setupLFSCloneFixture(t)
	t.Cleanup(fixture.server.Close)

	binDir := t.TempDir()
	buildGitReplycantBinary(t, filepath.Join(binDir, "git-replycant"))
	storeDir := filepath.Join(t.TempDir(), "lfs-store")
	require.NoError(t, os.MkdirAll(storeDir, 0o755))
	buildFakeGitLFSIntegrationBinary(t, filepath.Join(binDir, "git-lfs"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REPLYCANT_FAKE_LFS_STORE", storeDir)
	writeFakeLFSObject(t, storeDir, fixture.objectOID, fixture.objectBytes)

	repoDir := fixture.repoDir
	local := fixture.local
	repoURL := fixture.repoURL
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)

	require.NoError(t, PollAuthorization(context.Background(), repoURL, local, caFilePath))
	require.NoError(t, FetchRepository(context.Background(), repoDir, local, caFilePath, 0))
	require.NoError(t, ConfigureRepository(repoDir, fixture.lfsURL, local, caFilePath))
	branch, err := ResolveDefaultRemoteBranch(repoDir)
	require.NoError(t, err)
	require.NoError(t, PreExtractEncryptionFiles(context.Background(), repoDir, branch))

	progressOutput, checkoutErr := captureStderrOutput(t, func() error {
		return CheckoutTrackingBranch(context.Background(), repoDir, branch)
	})
	if checkoutErr != nil {
		if strings.Contains(checkoutErr.Error(), "smudge filter replycant-crypt failed") {
			t.Skipf("environment does not support LFS filter-process integration: %v", checkoutErr)
		}
		require.NoError(t, checkoutErr)
	}
	assert.Contains(t, progressOutput, "Downloading ")
}

// TestLFSSmudgeFailsWhenEpochFileMissing ensures missing KEK epochs fail checkout with actionable diagnostics.
func TestLFSSmudgeFailsWhenEpochFileMissing(t *testing.T) {
	fixture := setupLFSCloneFixtureMissingEpoch(t)
	t.Cleanup(fixture.server.Close)

	binDir := t.TempDir()
	buildGitReplycantBinary(t, filepath.Join(binDir, "git-replycant"))
	storeDir := filepath.Join(t.TempDir(), "lfs-store")
	require.NoError(t, os.MkdirAll(storeDir, 0o755))
	buildFakeGitLFSIntegrationBinary(t, filepath.Join(binDir, "git-lfs"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REPLYCANT_FAKE_LFS_STORE", storeDir)
	writeFakeLFSObject(t, storeDir, fixture.objectOID, fixture.objectBytes)

	repoDir := fixture.repoDir
	local := fixture.local
	repoURL := fixture.repoURL
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)

	require.NoError(t, PollAuthorization(context.Background(), repoURL, local, caFilePath))
	require.NoError(t, FetchRepository(context.Background(), repoDir, local, caFilePath, 0))
	require.NoError(t, ConfigureRepository(repoDir, fixture.lfsURL, local, caFilePath))
	branch, err := ResolveDefaultRemoteBranch(repoDir)
	require.NoError(t, err)

	progressOutput, err := captureStderrOutput(t, func() error {
		return CheckoutTrackingBranch(context.Background(), repoDir, branch)
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "git checkout -B")
	assert.Contains(t, progressOutput, "smudge filter replycant-crypt failed")
	assert.Contains(t, progressOutput, "encryption/epochs/1.age")
	assert.Contains(t, progressOutput, "missing required KEK epoch file")
}

// setupCloneFixture provisions a bare repo and mock mTLS git server aligned to the destination repo identity.
func setupCloneFixture(t *testing.T, initiallyAuthorized bool) testCloneFixture {
	target := filepath.Join(t.TempDir(), "clone-target")
	options := CloneOptions{
		ServerURL: "http://placeholder.invalid:8080",
		Directory: target,
	}

	repoDir, err := InitializeRepository(context.Background(), options.Directory, "https://placeholder.invalid/repo.git", options.ServerURL, false)
	require.NoError(t, err)
	local, _, err := gitcrypt.EnsureLocalIdentity(repoDir, "integration-test-device")
	require.NoError(t, err)
	recipientPub := decodeAgePublicKeyForTest(t, local.Identity.AgePublicKey)

	plainManifest := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	projectRoot, repoName := createTestBareRepo(t, recipientPub, plainManifest)

	authorized := &atomic.Bool{}
	authorized.Store(initiallyAuthorized)
	server, caFilePath := startTestGitServer(t, projectRoot, authorized)
	repoURL := server.URL + "/" + repoName
	caPEM, err := os.ReadFile(caFilePath)
	require.NoError(t, err)
	configServer := startTestConfigServer(t, string(caPEM), repoURL)
	t.Cleanup(configServer.Close)
	require.NoError(t, SetOriginRemote(context.Background(), repoDir, repoURL))
	options.ServerURL = configServer.URL

	return testCloneFixture{
		repoDir:       repoDir,
		local:         local,
		options:       options,
		repoURL:       repoURL,
		lfsURL:        "",
		caPEM:         string(caPEM),
		plainManifest: plainManifest,
		server:        server,
	}
}

// prepareLFSClonedRepo performs clone setup for scenarios that also require git-lfs object resolution.
func prepareLFSClonedRepo(t *testing.T) testLFSCloneFixture {
	t.Helper()
	fixture := setupLFSCloneFixture(t)
	t.Cleanup(fixture.server.Close)

	binDir := t.TempDir()
	buildGitReplycantBinary(t, filepath.Join(binDir, "git-replycant"))
	storeDir := filepath.Join(t.TempDir(), "lfs-store")
	require.NoError(t, os.MkdirAll(storeDir, 0o755))
	buildFakeGitLFSIntegrationBinary(t, filepath.Join(binDir, "git-lfs"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("REPLYCANT_FAKE_LFS_STORE", storeDir)
	writeFakeLFSObject(t, storeDir, fixture.objectOID, fixture.objectBytes)

	repoDir := fixture.repoDir
	local := fixture.local
	repoURL := fixture.repoURL
	caFilePath, err := WriteCAToRepoReplycantDir(fixture.caPEM, local.ConfigDirectory)
	require.NoError(t, err)

	require.NoError(t, PollAuthorization(context.Background(), repoURL, local, caFilePath))
	require.NoError(t, FetchRepository(context.Background(), repoDir, local, caFilePath, 0))
	require.NoError(t, ConfigureRepository(repoDir, fixture.lfsURL, local, caFilePath))
	branch, err := ResolveDefaultRemoteBranch(repoDir)
	require.NoError(t, err)
	require.NoError(t, PreExtractEncryptionFiles(context.Background(), repoDir, branch))
	if err := CheckoutTrackingBranch(context.Background(), repoDir, branch); err != nil {
		if strings.Contains(err.Error(), "smudge filter replycant-crypt failed") {
			t.Skipf("environment does not support LFS filter-process integration: %v", err)
		}
		require.NoError(t, err)
	}
	fixture.lfsStoreDir = storeDir
	return fixture
}

// setupLFSCloneFixture provisions git and LFS servers with one encrypted binary pointer fixture.
func setupLFSCloneFixture(t *testing.T) testLFSCloneFixture {
	target := filepath.Join(t.TempDir(), "clone-target")
	options := CloneOptions{
		ServerURL: "http://placeholder.invalid:8080",
		Directory: target,
	}

	repoDir, err := InitializeRepository(context.Background(), options.Directory, "https://placeholder.invalid/repo.git", options.ServerURL, false)
	require.NoError(t, err)
	local, _, err := gitcrypt.EnsureLocalIdentity(repoDir, "integration-test-device")
	require.NoError(t, err)
	recipientPub := decodeAgePublicKeyForTest(t, local.Identity.AgePublicKey)

	plainManifest := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	plainBinary := []byte("hello-lfs-world")
	projectRoot, repoName, objectOID, encryptedObject := createTestBareRepoWithLFS(t, recipientPub, plainManifest, plainBinary)

	authorized := &atomic.Bool{}
	authorized.Store(true)
	server, caFilePath := startTestGitServer(t, projectRoot, authorized)
	repoURL := server.URL + "/" + repoName
	caPEM, err := os.ReadFile(caFilePath)
	require.NoError(t, err)
	configServer := startTestConfigServer(t, string(caPEM), repoURL)
	t.Cleanup(configServer.Close)
	require.NoError(t, SetOriginRemote(context.Background(), repoDir, repoURL))

	options.ServerURL = configServer.URL

	return testLFSCloneFixture{
		testCloneFixture: testCloneFixture{
			repoDir:       repoDir,
			local:         local,
			options:       options,
			repoURL:       repoURL,
			lfsURL:        "https://lfs.invalid",
			caPEM:         string(caPEM),
			plainManifest: plainManifest,
			server:        server,
		},
		plainBinary: plainBinary,
		objectOID:   objectOID,
		objectBytes: encryptedObject,
	}
}

// setupLFSCloneFixtureMissingEpoch creates LFS fixtures with pointers that reference a missing epoch envelope.
func setupLFSCloneFixtureMissingEpoch(t *testing.T) testLFSCloneFixture {
	target := filepath.Join(t.TempDir(), "clone-target")
	options := CloneOptions{
		ServerURL: "http://placeholder.invalid:8080",
		Directory: target,
	}

	repoDir, err := InitializeRepository(context.Background(), options.Directory, "https://placeholder.invalid/repo.git", options.ServerURL, false)
	require.NoError(t, err)
	local, _, err := gitcrypt.EnsureLocalIdentity(repoDir, "integration-test-device")
	require.NoError(t, err)

	plainManifest := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	plainBinary := []byte("hello-lfs-world")
	projectRoot, repoName, objectOID, encryptedObject := createTestBareRepoWithLFSMissingEpoch(t, plainManifest, plainBinary)

	authorized := &atomic.Bool{}
	authorized.Store(true)
	server, caFilePath := startTestGitServer(t, projectRoot, authorized)
	repoURL := server.URL + "/" + repoName
	caPEM, err := os.ReadFile(caFilePath)
	require.NoError(t, err)
	configServer := startTestConfigServer(t, string(caPEM), repoURL)
	t.Cleanup(configServer.Close)
	require.NoError(t, SetOriginRemote(context.Background(), repoDir, repoURL))

	options.ServerURL = configServer.URL

	return testLFSCloneFixture{
		testCloneFixture: testCloneFixture{
			repoDir:       repoDir,
			local:         local,
			options:       options,
			repoURL:       repoURL,
			lfsURL:        "https://lfs.invalid",
			caPEM:         string(caPEM),
			plainManifest: plainManifest,
			server:        server,
		},
		plainBinary: plainBinary,
		objectOID:   objectOID,
		objectBytes: encryptedObject,
	}
}

// setServerAuthorized flips authorization state on a running mock server.
func setServerAuthorized(t *testing.T, server *httptest.Server, value bool) {
	t.Helper()
	ptr := server.Config.Handler.(*testServerHandler).authorized
	ptr.Store(value)
}

// testServerHandler guards git-http-backend with auth toggling used by polling tests.
type testServerHandler struct {
	authorized *atomic.Bool
	next       http.Handler
}

// ServeHTTP returns 401 until authorized, then proxies requests to git-http-backend.
func (h *testServerHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !h.authorized.Load() {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	h.next.ServeHTTP(w, r)
}

// startTestGitServer runs an mTLS HTTPS server backed by git-http-backend for integration tests.
func startTestGitServer(t *testing.T, projectRoot string, authorized *atomic.Bool) (*httptest.Server, string) {
	t.Helper()
	caCertPEM, caKey := generateTestCA(t)
	serverCert := generateTestServerCert(t, caCertPEM, caKey)

	caFilePath := filepath.Join(t.TempDir(), "ca.pem")
	testWriteFile(t, caFilePath, caCertPEM, 0o644)

	gitExecPath := strings.TrimSpace(testRunGit(t, "", "--exec-path"))
	backend := filepath.Join(gitExecPath, "git-http-backend")
	cgiHandler := &cgi.Handler{
		Path: backend,
		Env: []string{
			"GIT_PROJECT_ROOT=" + projectRoot,
			"GIT_HTTP_EXPORT_ALL=1",
		},
	}
	handler := &testServerHandler{
		authorized: authorized,
		next:       cgiHandler,
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAnyClientCert,
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server, caFilePath
}

// startTestConfigServer serves caserver discovery responses so clone tests follow the production bootstrap contract.
func startTestConfigServer(t *testing.T, caPEM string, repoURL string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/config.json" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(DiscoveredServerConfig{
			CA:  caPEM,
			URL: repoURL,
		})
	}))
}

// createTestBareRepo builds a minimal repository with encrypted manifest fixtures for clone-flow tests.
func createTestBareRepo(t *testing.T, recipientAgePub []byte, plaintext []byte) (string, string) {
	t.Helper()
	projectRoot := t.TempDir()
	workDir := filepath.Join(projectRoot, "work")
	repoName := "origin.git"
	bareDir := filepath.Join(projectRoot, repoName)
	testRunGit(t, "", "init", workDir)

	kek := make([]byte, 32)
	_, err := rand.Read(kek)
	require.NoError(t, err)
	envelope := wrapKEKForTest(t, kek, recipientAgePub)

	encryptedManifest, err := gitcrypt.EncryptManifestEnvelope(plaintext, kek, 1)
	require.NoError(t, err)
	testWriteFile(t, filepath.Join(workDir, "encryption", "current"), []byte("1\n"), 0o644)
	testWriteFile(t, filepath.Join(workDir, "encryption", "epochs", "1.age"), envelope, 0o644)
	testWriteFile(t, filepath.Join(workDir, "manifests", "test-device", "test.yaml"), encryptedManifest, 0o644)

	testRunGit(t, workDir, "add", ".")
	testRunGit(t, workDir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "fixtures")
	testRunGit(t, "", "clone", "--bare", workDir, bareDir)
	gittest.DisableAutoMaintenance(t, bareDir)
	testRunGit(t, bareDir, "config", "http.receivepack", "true")
	testRunGit(t, bareDir, "update-server-info")
	return projectRoot, repoName
}

// createTestBareRepoWithLFS builds fixtures that include one encrypted LFS pointer and object payload.
func createTestBareRepoWithLFS(t *testing.T, recipientAgePub []byte, manifestPlaintext []byte, binaryPlaintext []byte) (string, string, string, []byte) {
	t.Helper()
	projectRoot := t.TempDir()
	workDir := filepath.Join(projectRoot, "work")
	repoName := "origin.git"
	bareDir := filepath.Join(projectRoot, repoName)
	testRunGit(t, "", "init", workDir)

	kek := make([]byte, 32)
	_, err := rand.Read(kek)
	require.NoError(t, err)
	envelope := wrapKEKForTest(t, kek, recipientAgePub)

	encryptedManifest, err := gitcrypt.EncryptManifestEnvelope(manifestPlaintext, kek, 1)
	require.NoError(t, err)
	dek, err := gitcrypt.NewDEK()
	require.NoError(t, err)
	encryptedBinary, err := gitcrypt.EncryptChunked(binaryPlaintext, dek)
	require.NoError(t, err)
	objectDigest := sha256.Sum256(encryptedBinary)
	objectOID := fmt.Sprintf("%x", objectDigest[:])
	wrappedDEK, err := gitcrypt.WrapDEK(kek, dek, 1)
	require.NoError(t, err)
	basePointer := fmt.Sprintf("version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n", objectOID, len(encryptedBinary))
	fullPointer, err := gitcrypt.AppendReplycantHeaders([]byte(basePointer), 1, wrappedDEK)
	require.NoError(t, err)

	testWriteFile(t, filepath.Join(workDir, "encryption", "current"), []byte("1\n"), 0o644)
	testWriteFile(t, filepath.Join(workDir, "encryption", "epochs", "1.age"), envelope, 0o644)
	testWriteFile(t, filepath.Join(workDir, "manifests", "test-device", "test.yaml"), encryptedManifest, 0o644)
	testWriteFile(t, filepath.Join(workDir, "binary", "test.bin"), fullPointer, 0o644)

	testRunGit(t, workDir, "add", ".")
	testRunGit(t, workDir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "fixtures")
	testRunGit(t, "", "clone", "--bare", workDir, bareDir)
	gittest.DisableAutoMaintenance(t, bareDir)
	testRunGit(t, bareDir, "config", "http.receivepack", "true")
	testRunGit(t, bareDir, "update-server-info")
	return projectRoot, repoName, objectOID, encryptedBinary
}

// createTestBareRepoWithLFSMissingEpoch builds one LFS pointer fixture while omitting its referenced epoch file.
func createTestBareRepoWithLFSMissingEpoch(t *testing.T, manifestPlaintext []byte, binaryPlaintext []byte) (string, string, string, []byte) {
	t.Helper()
	projectRoot := t.TempDir()
	workDir := filepath.Join(projectRoot, "work")
	repoName := "origin.git"
	bareDir := filepath.Join(projectRoot, repoName)
	testRunGit(t, "", "init", workDir)

	kek := make([]byte, 32)
	_, err := rand.Read(kek)
	require.NoError(t, err)

	encryptedManifest, err := gitcrypt.EncryptManifestEnvelope(manifestPlaintext, kek, 1)
	require.NoError(t, err)
	dek, err := gitcrypt.NewDEK()
	require.NoError(t, err)
	encryptedBinary, err := gitcrypt.EncryptChunked(binaryPlaintext, dek)
	require.NoError(t, err)
	objectDigest := sha256.Sum256(encryptedBinary)
	objectOID := fmt.Sprintf("%x", objectDigest[:])
	wrappedDEK, err := gitcrypt.WrapDEK(kek, dek, 1)
	require.NoError(t, err)
	basePointer := fmt.Sprintf("version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n", objectOID, len(encryptedBinary))
	fullPointer, err := gitcrypt.AppendReplycantHeaders([]byte(basePointer), 1, wrappedDEK)
	require.NoError(t, err)

	testWriteFile(t, filepath.Join(workDir, "encryption", "current"), []byte("1\n"), 0o644)
	testWriteFile(t, filepath.Join(workDir, "manifests", "test-device", "test.yaml"), encryptedManifest, 0o644)
	testWriteFile(t, filepath.Join(workDir, "binary", "test.bin"), fullPointer, 0o644)

	testRunGit(t, workDir, "add", ".")
	testRunGit(t, workDir, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "fixtures")
	testRunGit(t, "", "clone", "--bare", workDir, bareDir)
	gittest.DisableAutoMaintenance(t, bareDir)
	testRunGit(t, bareDir, "config", "http.receivepack", "true")
	testRunGit(t, bareDir, "update-server-info")
	return projectRoot, repoName, objectOID, encryptedBinary
}

// buildFakeGitLFSIntegrationBinary builds a fake git-lfs process that stores encrypted bytes in one local directory.
func buildFakeGitLFSIntegrationBinary(t *testing.T, outputPath string) {
	t.Helper()
	source := filepath.Join(t.TempDir(), "fake_git_lfs_integration.go")
	code := `package main
import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)
func readPacket(r *bufio.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil { return nil, err }
	n, err := strconv.ParseInt(string(header), 16, 32)
	if err != nil { return nil, err }
	if n == 0 { return nil, nil }
	payload := make([]byte, int(n)-4)
	_, err = io.ReadFull(r, payload)
	return payload, err
}
func readUntilFlush(r *bufio.Reader) ([][]byte, error) {
	out := [][]byte{}
	for {
		p, err := readPacket(r)
		if err != nil { return nil, err }
		if p == nil { return out, nil }
		out = append(out, p)
	}
}
func writePacket(w *bufio.Writer, payload []byte) error {
	if _, err := fmt.Fprintf(w, "%04x", len(payload)+4); err != nil { return err }
	if len(payload) == 0 { return nil }
	_, err := w.Write(payload)
	return err
}
func writeFlush(w *bufio.Writer) error { _, err := w.WriteString("0000"); return err }
func writeSuccess(w *bufio.Writer, data []byte) error {
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	if len(data) > 0 {
		if err := writePacket(w, data); err != nil { return err }
	}
	if err := writeFlush(w); err != nil { return err }
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	return w.Flush()
}
func objectPath(store string, oid string) string {
	if len(oid) < 4 { return filepath.Join(store, oid) }
	return filepath.Join(store, oid[:2], oid[2:4], oid)
}
func readObject(store string, oid string) ([]byte, error) {
	return os.ReadFile(objectPath(store, oid))
}
func writeObject(store string, oid string, body []byte) error {
	path := objectPath(store, oid)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil { return err }
	return os.WriteFile(path, body, 0o644)
}
func parsePointerOID(raw []byte) string {
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "oid sha256:") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "oid sha256:"))
		}
	}
	return ""
}
func writePointer(oid string, size int) []byte {
	return []byte(fmt.Sprintf("version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n", oid, size))
}
func filterProcess(store string) int {
	r := bufio.NewReader(os.Stdin)
	w := bufio.NewWriter(os.Stdout)
	if _, err := readUntilFlush(r); err != nil { return 1 }
	_ = writePacket(w, []byte("git-filter-server\n"))
	_ = writePacket(w, []byte("version=2\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	if _, err := readUntilFlush(r); err != nil { return 1 }
	_ = writePacket(w, []byte("capability=clean\n"))
	_ = writePacket(w, []byte("capability=smudge\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	for {
		header, err := readUntilFlush(r)
		if err == io.EOF { return 0 }
		if err != nil { return 1 }
		dataFrames, err := readUntilFlush(r)
		if err != nil { return 1 }
		command := ""
		for _, packet := range header {
			line := strings.TrimSpace(string(packet))
			if strings.HasPrefix(line, "command=") { command = strings.TrimPrefix(line, "command=") }
		}
		data := []byte{}
		for _, frame := range dataFrames { data = append(data, frame...) }
		switch command {
		case "clean":
			sum := sha256.Sum256(data)
			oid := fmt.Sprintf("%x", sum[:])
			if err := writeObject(store, oid, data); err != nil { return 1 }
			if err := writeSuccess(w, writePointer(oid, len(data))); err != nil { return 1 }
		case "smudge":
			oid := parsePointerOID(data)
			body, err := readObject(store, oid)
			if err != nil { return 1 }
			fmt.Fprintf(os.Stderr, "Downloading %s (%d bytes)\n", oid, len(body))
			if err := writeSuccess(w, body); err != nil { return 1 }
		default:
			return 1
		}
	}
}
func main() {
	store := os.Getenv("REPLYCANT_FAKE_LFS_STORE")
	if strings.TrimSpace(store) == "" { os.Exit(1) }
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		fmt.Println("git-lfs/3.0.0-fake")
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "filter-process" {
		os.Exit(filterProcess(store))
	}
	os.Exit(1)
}
`
	require.NoError(t, os.WriteFile(source, []byte(code), 0o644))
	cmd := exec.Command("go", "build", "-o", outputPath, source)
	out, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "failed to build fake integration git-lfs: %s", string(out))
}

// writeFakeLFSObject seeds one encrypted object in the fake LFS store used by filter-process smudge tests.
func writeFakeLFSObject(t *testing.T, storeDir string, oid string, body []byte) {
	t.Helper()
	require.Len(t, oid, 64)
	path := filepath.Join(storeDir, oid[:2], oid[2:4], oid)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, body, 0o644))
}

// captureStderrOutput records stderr during one operation so tests can assert real-time progress visibility.
func captureStderrOutput(t *testing.T, run func() error) (string, error) {
	t.Helper()
	reader, writer, err := os.Pipe()
	require.NoError(t, err)
	originalStderr := os.Stderr
	os.Stderr = writer
	defer func() {
		os.Stderr = originalStderr
	}()

	runErr := run()
	require.NoError(t, writer.Close())
	output, readErr := io.ReadAll(reader)
	require.NoError(t, readErr)
	require.NoError(t, reader.Close())
	return string(output), runErr
}

// readFakeLFSObject loads one encrypted object from the fake LFS store for assertion checks.
func readFakeLFSObject(storeDir string, oid string) ([]byte, bool) {
	if len(oid) != 64 {
		return nil, false
	}
	path := filepath.Join(storeDir, oid[:2], oid[2:4], oid)
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	return body, true
}

// fakeLFSBatch types are local JSON shapes for the integration fake LFS server.
type fakeLFSObject struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

type fakeLFSBatchRequest struct {
	Operation string          `json:"operation"`
	Objects   []fakeLFSObject `json:"objects"`
}

type fakeLFSBatchAction struct {
	Href string `json:"href"`
}

type fakeLFSBatchObject struct {
	OID     string                        `json:"oid"`
	Size    int64                         `json:"size"`
	Actions map[string]fakeLFSBatchAction `json:"actions,omitempty"`
}

type fakeLFSBatchResponse struct {
	Transfer string               `json:"transfer"`
	Objects  []fakeLFSBatchObject `json:"objects"`
}

// startFakeLFSBatchServer provides upload/verify endpoints compatible with basic Git LFS batch flows.
func startFakeLFSBatchServer(t *testing.T, storeDir string) *httptest.Server {
	t.Helper()
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/objects/batch":
			var batchReq fakeLFSBatchRequest
			require.NoError(t, json.NewDecoder(r.Body).Decode(&batchReq))
			require.Equal(t, "upload", batchReq.Operation)
			response := fakeLFSBatchResponse{
				Transfer: "basic",
				Objects:  make([]fakeLFSBatchObject, 0, len(batchReq.Objects)),
			}
			for _, object := range batchReq.Objects {
				if _, exists := readFakeLFSObject(storeDir, object.OID); exists {
					response.Objects = append(response.Objects, fakeLFSBatchObject{
						OID:  object.OID,
						Size: object.Size,
					})
					continue
				}
				response.Objects = append(response.Objects, fakeLFSBatchObject{
					OID:  object.OID,
					Size: object.Size,
					Actions: map[string]fakeLFSBatchAction{
						"upload": {Href: server.URL + "/upload/" + object.OID},
						"verify": {Href: server.URL + "/verify/" + object.OID},
					},
				})
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/upload/"):
			oid := strings.TrimPrefix(r.URL.Path, "/upload/")
			body, err := io.ReadAll(r.Body)
			require.NoError(t, err)
			writeFakeLFSObject(t, storeDir, oid, body)
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/verify/"):
			var verifyReq fakeLFSObject
			require.NoError(t, json.NewDecoder(r.Body).Decode(&verifyReq))
			body, exists := readFakeLFSObject(storeDir, verifyReq.OID)
			if !exists {
				http.Error(w, "missing object", http.StatusNotFound)
				return
			}
			if int64(len(body)) != verifyReq.Size {
				http.Error(w, "size mismatch", http.StatusConflict)
				return
			}
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	return server
}

// copyTestDirectory mirrors one small fixture directory tree for second-clone identity reuse.
func copyTestDirectory(sourceDir string, targetDir string) error {
	return filepath.WalkDir(sourceDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(sourceDir, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(targetDir, relative)
		if d.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(destination, raw, 0o600)
	})
}

// decodeAgePublicKeyForTest converts bech32 age recipient strings into raw X25519 public key bytes.
func decodeAgePublicKeyForTest(t *testing.T, agePublicKey string) []byte {
	t.Helper()
	hrp, data, err := bech32.Decode(agePublicKey)
	require.NoError(t, err)
	require.Equal(t, "age", hrp)
	raw, err := bech32.ConvertBits(data, 5, 8, false)
	require.NoError(t, err)
	require.Len(t, raw, 32)
	return raw
}

// wrapKEKForTest creates age envelope text compatible with gitcrypt.UnwrapKEKFromAgeEnvelope for deterministic fixtures.
func wrapKEKForTest(t *testing.T, kek []byte, recipientAgePub []byte) []byte {
	t.Helper()
	fileKey := make([]byte, 32)
	_, err := rand.Read(fileKey)
	require.NoError(t, err)

	ephemeralPriv := make([]byte, 32)
	_, err = rand.Read(ephemeralPriv)
	require.NoError(t, err)
	ephemeralPub, err := curve25519.X25519(ephemeralPriv, curve25519.Basepoint)
	require.NoError(t, err)

	sharedSecret, err := curve25519.X25519(ephemeralPriv, recipientAgePub)
	require.NoError(t, err)
	wrapKey, err := deriveWrapKey(sharedSecret)
	require.NoError(t, err)

	wrappedFileKey, err := encryptChaChaCombined(wrapKey, fileKey)
	require.NoError(t, err)
	payload, err := encryptChaChaCombined(fileKey, kek)
	require.NoError(t, err)

	envelope := strings.Join([]string{
		"age-encryption.org/v1",
		fmt.Sprintf("-> X25519 %s %s", base64.StdEncoding.EncodeToString(ephemeralPub), base64.StdEncoding.EncodeToString(wrappedFileKey)),
		"payload " + base64.StdEncoding.EncodeToString(payload),
		"",
	}, "\n")
	return []byte(envelope)
}

// encryptChaChaCombined mirrors decryptChaChaCombined's framing for test fixture generation.
func encryptChaChaCombined(key []byte, plaintext []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	ciphertextWithTag := aead.Seal(nil, nonce, plaintext, nil)
	out := make([]byte, 0, len(nonce)+len(ciphertextWithTag))
	out = append(out, nonce...)
	out = append(out, ciphertextWithTag...)
	return out, nil
}

// generateTestCA creates a CA certificate used to issue the mock HTTPS server certificate.
func generateTestCA(t *testing.T) ([]byte, *ecdsa.PrivateKey) {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "replycant-test-ca"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, template, template, &caKey.PublicKey, caKey)
	require.NoError(t, err)
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	return caPEM, caKey
}

// generateTestServerCert issues a server certificate signed by the test CA for localhost TLS traffic.
func generateTestServerCert(t *testing.T, caCertPEM []byte, caKey *ecdsa.PrivateKey) tls.Certificate {
	t.Helper()
	caBlock, _ := pem.Decode(caCertPEM)
	require.NotNil(t, caBlock)
	caCert, err := x509.ParseCertificate(caBlock.Bytes)
	require.NoError(t, err)

	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, template, caCert, &serverKey.PublicKey, caKey)
	require.NoError(t, err)
	serverKeyDER, err := x509.MarshalECPrivateKey(serverKey)
	require.NoError(t, err)

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: serverKeyDER})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	require.NoError(t, err)
	return cert
}

// buildGitReplycantBinary compiles a real git-replycant executable so checkout filters run exactly as production.
func buildGitReplycantBinary(t *testing.T, outputPath string) {
	t.Helper()
	cwd, err := os.Getwd()
	require.NoError(t, err)
	cmd := exec.Command("go", "build", "-o", outputPath, ".")
	cmd.Dir = cwd
	out, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "go build failed: %s", string(out))
}
