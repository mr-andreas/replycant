package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParsePrePushUpdates verifies git hook stdin lines are parsed into ref update structs.
func TestParsePrePushUpdates(t *testing.T) {
	raw := strings.Join([]string{
		"refs/heads/main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"refs/heads/feature cccccccccccccccccccccccccccccccccccccccc refs/heads/feature 0000000000000000000000000000000000000000",
		"",
	}, "\n")
	updates, err := parsePrePushUpdates(strings.NewReader(raw))
	require.NoError(t, err)
	require.Len(t, updates, 2)
	assert.Equal(t, "refs/heads/main", updates[0].LocalRef)
	assert.Equal(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", updates[0].LocalSHA)
	assert.Equal(t, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", updates[0].RemoteSHA)
	assert.Equal(t, "refs/heads/feature", updates[1].RemoteRef)
}

// TestCollectUpdatedLFSObjects finds Replycant pointer OIDs from binary paths touched by pushed commits.
func TestCollectUpdatedLFSObjects(t *testing.T) {
	repo := testInitRepo(t)
	pointer := strings.Join([]string{
		"version https://git-lfs.github.com/spec/v1",
		"oid sha256:1111111111111111111111111111111111111111111111111111111111111111",
		"size 123",
		"x-replycant-kek-epoch 1",
		"x-replycant-wrapped-dek test",
		"",
	}, "\n")
	testWriteFile(t, filepath.Join(repo, "binary", "test.bin"), []byte(pointer), 0o644)
	testRunGit(t, repo, "add", "binary/test.bin")
	testRunGit(t, repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "add pointer")
	localSHA := strings.TrimSpace(testRunGit(t, repo, "rev-parse", "HEAD"))

	objects, refName, err := collectUpdatedLFSObjects(repo, "origin", []prePushRefUpdate{
		{
			LocalRef:  "refs/heads/main",
			LocalSHA:  localSHA,
			RemoteRef: "refs/heads/main",
			RemoteSHA: zeroGitObjectID,
		},
	})
	require.NoError(t, err)
	assert.Equal(t, "refs/heads/main", refName)
	require.Len(t, objects, 1)
	assert.Equal(t, "1111111111111111111111111111111111111111111111111111111111111111", objects[0].OID)
	assert.EqualValues(t, 123, objects[0].Size)
}

// TestCollectUpdatedLFSObjectsUnknownRemoteTip ensures a concurrent remote tip that
// is not present locally does not abort the scan; objects from local commits are still found.
func TestCollectUpdatedLFSObjectsUnknownRemoteTip(t *testing.T) {
	repo := testInitRepo(t)
	pointer := strings.Join([]string{
		"version https://git-lfs.github.com/spec/v1",
		"oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"size 10",
		"x-replycant-kek-epoch 1",
		"x-replycant-wrapped-dek test",
		"",
	}, "\n")
	testWriteFile(t, filepath.Join(repo, "binary", "a.bin"), []byte(pointer), 0o644)
	testRunGit(t, repo, "add", "binary/a.bin")
	testRunGit(t, repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "add a")
	localSHA := strings.TrimSpace(testRunGit(t, repo, "rev-parse", "HEAD"))
	unknownRemote := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	objects, refName, err := collectUpdatedLFSObjects(repo, "origin", []prePushRefUpdate{
		{
			LocalRef:  "refs/heads/main",
			LocalSHA:  localSHA,
			RemoteRef: "refs/heads/main",
			RemoteSHA: unknownRemote,
		},
	})
	require.NoError(t, err)
	assert.Equal(t, "refs/heads/main", refName)
	require.Len(t, objects, 1)
	assert.Equal(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", objects[0].OID)
}

// TestCollectUpdatedLFSObjectsUnknownRemoteTipUsesTrackingRefs proves that when the
// remote tip is missing locally, the scan is bounded by remote-tracking refs so
// already-pushed commits are excluded (matching git-lfs behavior).
func TestCollectUpdatedLFSObjectsUnknownRemoteTipUsesTrackingRefs(t *testing.T) {
	repo := testInitRepo(t)
	testRunGit(t, repo, "config", "remote.origin.url", "https://example.com/repo.git")

	firstPointer := strings.Join([]string{
		"version https://git-lfs.github.com/spec/v1",
		"oid sha256:1111111111111111111111111111111111111111111111111111111111111111",
		"size 11",
		"x-replycant-kek-epoch 1",
		"x-replycant-wrapped-dek first",
		"",
	}, "\n")
	testWriteFile(t, filepath.Join(repo, "binary", "first.bin"), []byte(firstPointer), 0o644)
	testRunGit(t, repo, "add", "binary/first.bin")
	testRunGit(t, repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "first")
	firstSHA := strings.TrimSpace(testRunGit(t, repo, "rev-parse", "HEAD"))
	testRunGit(t, repo, "update-ref", "refs/remotes/origin/main", firstSHA)

	secondPointer := strings.Join([]string{
		"version https://git-lfs.github.com/spec/v1",
		"oid sha256:2222222222222222222222222222222222222222222222222222222222222222",
		"size 22",
		"x-replycant-kek-epoch 1",
		"x-replycant-wrapped-dek second",
		"",
	}, "\n")
	testWriteFile(t, filepath.Join(repo, "binary", "second.bin"), []byte(secondPointer), 0o644)
	testRunGit(t, repo, "add", "binary/second.bin")
	testRunGit(t, repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-m", "second")
	localSHA := strings.TrimSpace(testRunGit(t, repo, "rev-parse", "HEAD"))
	unknownRemote := "cccccccccccccccccccccccccccccccccccccccc"

	objects, _, err := collectUpdatedLFSObjects(repo, "origin", []prePushRefUpdate{
		{
			LocalRef:  "refs/heads/main",
			LocalSHA:  localSHA,
			RemoteRef: "refs/heads/main",
			RemoteSHA: unknownRemote,
		},
	})
	require.NoError(t, err)
	require.Len(t, objects, 1)
	assert.Equal(t, "2222222222222222222222222222222222222222222222222222222222222222", objects[0].OID)
}

// TestBuildLFSHTTPClient validates pre-push can construct an mTLS-ready client from local git config.
func TestBuildLFSHTTPClient(t *testing.T) {
	repo := testInitRepo(t)
	local, _, err := gitcrypt.EnsureLocalIdentity(repo, "test-device")
	require.NoError(t, err)

	caPath := filepath.Join(t.TempDir(), "ca.pem")
	certPEM, err := os.ReadFile(local.ClientCertPath)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(caPath, certPEM, 0o644))

	testRunGit(t, repo, "config", "--local", "http.sslCAInfo", caPath)
	testRunGit(t, repo, "config", "--local", "http.sslCert", local.ClientCertPath)
	testRunGit(t, repo, "config", "--local", "http.sslKey", local.ClientKeyPath)

	client, err := buildLFSHTTPClient(repo)
	require.NoError(t, err)
	require.NotNil(t, client)
	transport, ok := client.Transport.(*http.Transport)
	require.True(t, ok)
	require.NotNil(t, transport.DialContext)
	require.NotNil(t, transport.TLSClientConfig)
	assert.Len(t, transport.TLSClientConfig.Certificates, 1)
}

// TestBuildLFSHTTPClientMissingConfig ensures pre-push fails with a clear error when clone setup omitted mTLS config.
func TestBuildLFSHTTPClientMissingConfig(t *testing.T) {
	repo := testInitRepo(t)
	_, err := buildLFSHTTPClient(repo)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "http.sslCAInfo")
}

// TestOpenLocalLFSObject reads objects from the standard git-lfs object layout.
func TestOpenLocalLFSObject(t *testing.T) {
	repo := testInitRepo(t)
	gitDir, err := resolveGitDir(repo)
	require.NoError(t, err)

	oid := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	objectBody := []byte("test-payload")
	testWriteFile(t, filepath.Join(gitDir, "lfs", "objects", oid[:2], oid[2:4], oid), objectBody, 0o644)

	reader, err := openLocalLFSObject(gitDir)(lfsclient.Object{OID: oid, Size: int64(len(objectBody))})
	require.NoError(t, err)
	defer reader.Close()
	got, err := io.ReadAll(reader)
	require.NoError(t, err)
	assert.Equal(t, objectBody, got)
}
