package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRejectsFullLFSClone ensures filter-driven clones fail at boot with a
// clear --no-lfs instruction instead of silently writing plaintext binaries.
func TestRejectsFullLFSClone(t *testing.T) {
	repo := initTempRepo(t)
	gitDir := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "--git-dir"))
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(repo, gitDir)
	}
	infoDir := filepath.Join(gitDir, "info")
	require.NoError(t, os.MkdirAll(infoDir, 0o755))
	require.NoError(t, os.WriteFile(
		filepath.Join(infoDir, "attributes"),
		[]byte("binary/** filter=replycant-crypt\n"),
		0o644,
	))

	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	imp, _, _, _ := newTestImporter(t, nil)
	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--no-lfs")
}

// TestRejectsLFSURLConfig rejects clones that still have lfs.url even without filters.
func TestRejectsLFSURLConfig(t *testing.T) {
	repo := initTempRepo(t)
	mustRun(t, repo, "git", "config", "--local", "lfs.url", "https://example.com/lfs")

	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	imp, _, _, _ := newTestImporter(t, nil)
	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--no-lfs")
}

// TestUploadFailureSkipsFileWithoutCommit leaves the repo unchanged when LFS
// upload fails for a file, releasing the reserved SHA for later retries.
func TestUploadFailureSkipsFileWithoutCommit(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	before := commitCount(t, repo)

	imp, stderr, _, _ := newTestImporter(t, nil)
	imp.uploadObjects = func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
		return fmt.Errorf("injected upload failure")
	}
	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	})
	require.NoError(t, err)
	assert.Equal(t, before, commitCount(t, repo))
	assert.Contains(t, stderr.String(), "injected upload failure")
	originals, _ := listManifestPaths(t, repo, "device-a")
	assert.Empty(t, originals)
}

// TestDirectLFSUploadWritesPointersAndCiphertext verifies pointers land in the
// worktree, ciphertext reaches the fake LFS server, and no plaintext binary
// payload remains under the repo.
func TestDirectLFSUploadWritesPointersAndCiphertext(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	sourcePath := filepath.Join(srcDir, "a.jpg")
	writeTinyJPEG(t, sourcePath)
	plaintext, err := os.ReadFile(sourcePath)
	require.NoError(t, err)

	store := &sync.Map{}
	server := startImporterFakeLFSServer(t, store)
	defer server.Close()

	imp, _, _, _ := newTestImporter(t, nil)
	endpoint, err := lfsclient.ParseEndpoint(server.URL)
	require.NoError(t, err)
	client := &lfsclient.Client{HTTP: server.Client(), Endpoint: endpoint, Log: io.Discard}
	imp.uploadObjects = func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
		return client.Upload(ctx, "", objects, open)
	}

	require.NoError(t, imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	}))

	originals, thumbs := listManifestPaths(t, repo, "device-a")
	require.Len(t, originals, 1)
	require.Len(t, thumbs, 1)

	var om OriginalManifest
	readYAML(t, originals[0], &om)
	binaryPath := filepath.Join(repo, "binary", "device-a", apiVersion, "Original", shardName(om.Metadata.Name))
	pointerRaw, err := os.ReadFile(binaryPath)
	require.NoError(t, err)
	assert.True(t, gitcrypt.IsLFSPointer(pointerRaw))
	pointer, err := gitcrypt.ParseLFSPointer(pointerRaw)
	require.NoError(t, err)
	assert.Equal(t, 1, pointer.KekEpoch)
	assert.NotEmpty(t, pointer.WrappedDEK)

	cipherAny, ok := store.Load(pointer.OID)
	require.True(t, ok, "original ciphertext missing from LFS store")
	ciphertext := cipherAny.([]byte)
	assert.EqualValues(t, len(ciphertext), pointer.Size)

	local, err := gitcrypt.LoadLocalIdentity(repo)
	require.NoError(t, err)
	envelope, err := os.ReadFile(filepath.Join(repo, "encryption", "epochs", "1.age"))
	require.NoError(t, err)
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(envelope, local.Identity.AgePrivateKeyBase64)
	require.NoError(t, err)
	dek, err := gitcrypt.UnwrapDEK(pointer.WrappedDEK, kek, pointer.KekEpoch)
	require.NoError(t, err)
	got, err := gitcrypt.DecryptChunked(ciphertext, dek)
	require.NoError(t, err)
	assert.Equal(t, plaintext, got)

	var tm ThumbnailSetManifest
	readYAML(t, thumbs[0], &tm)
	require.Len(t, tm.Spec.Thumbnails, 3)
	for _, entry := range tm.Spec.Thumbnails {
		thumbPath := filepath.Join(repo, "binary", "device-a", apiVersion, "ThumbnailSet", shardName(entry.Name))
		thumbPointerRaw, err := os.ReadFile(thumbPath)
		require.NoError(t, err)
		assert.True(t, gitcrypt.IsLFSPointer(thumbPointerRaw), entry.Name)
		thumbPointer, err := gitcrypt.ParseLFSPointer(thumbPointerRaw)
		require.NoError(t, err)
		thumbCipherAny, ok := store.Load(thumbPointer.OID)
		require.True(t, ok, entry.Name)
		thumbCipher := thumbCipherAny.([]byte)
		thumbDEK, err := gitcrypt.UnwrapDEK(thumbPointer.WrappedDEK, kek, thumbPointer.KekEpoch)
		require.NoError(t, err)
		thumbPlain, err := gitcrypt.DecryptChunked(thumbCipher, thumbDEK)
		require.NoError(t, err)
		assert.EqualValues(t, entry.Filesize, len(thumbPlain))
		assert.False(t, gitcrypt.IsLFSPointer(thumbPlain))
	}

	err = filepath.WalkDir(filepath.Join(repo, "binary"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		raw, readErr := os.ReadFile(path)
		require.NoError(t, readErr)
		assert.True(t, gitcrypt.IsLFSPointer(raw), "binary path %s is not a pointer", path)
		return nil
	})
	require.NoError(t, err)
}

type fakeLFSObjectJSON struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

type fakeLFSBatchRequestJSON struct {
	Operation string              `json:"operation"`
	Objects   []fakeLFSObjectJSON `json:"objects"`
}

type fakeLFSBatchActionJSON struct {
	Href string `json:"href"`
}

type fakeLFSBatchObjectJSON struct {
	OID     string                            `json:"oid"`
	Size    int64                             `json:"size"`
	Actions map[string]fakeLFSBatchActionJSON `json:"actions,omitempty"`
}

type fakeLFSBatchResponseJSON struct {
	Transfer string                   `json:"transfer"`
	Objects  []fakeLFSBatchObjectJSON `json:"objects"`
}

// startImporterFakeLFSServer stores uploaded objects for ciphertext round-trip assertions.
func startImporterFakeLFSServer(t *testing.T, store *sync.Map) *httptest.Server {
	t.Helper()
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/objects/batch":
			var batchReq fakeLFSBatchRequestJSON
			require.NoError(t, json.NewDecoder(r.Body).Decode(&batchReq))
			response := fakeLFSBatchResponseJSON{
				Transfer: "basic",
				Objects:  make([]fakeLFSBatchObjectJSON, 0, len(batchReq.Objects)),
			}
			for _, object := range batchReq.Objects {
				if _, ok := store.Load(object.OID); ok {
					response.Objects = append(response.Objects, fakeLFSBatchObjectJSON{
						OID:  object.OID,
						Size: object.Size,
					})
					continue
				}
				response.Objects = append(response.Objects, fakeLFSBatchObjectJSON{
					OID:  object.OID,
					Size: object.Size,
					Actions: map[string]fakeLFSBatchActionJSON{
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
			store.Store(oid, append([]byte{}, body...))
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/verify/"):
			var verifyReq fakeLFSObjectJSON
			require.NoError(t, json.NewDecoder(r.Body).Decode(&verifyReq))
			bodyAny, ok := store.Load(verifyReq.OID)
			if !ok {
				http.Error(w, "missing", http.StatusNotFound)
				return
			}
			body := bodyAny.([]byte)
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
