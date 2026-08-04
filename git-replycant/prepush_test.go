package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
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

// TestSendLFSBatchRequest verifies that the batch endpoint receives a well-formed upload request
// and the parsed response is returned to the caller for per-object processing.
func TestSendLFSBatchRequest(t *testing.T) {
	oid := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	var receivedPayload lfsBatchRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/lfs/objects/batch", r.URL.Path)
		require.Equal(t, http.MethodPost, r.Method)
		require.Equal(t, "application/vnd.git-lfs+json", r.Header.Get("Content-Type"))
		require.Equal(t, "Basic dTpw", r.Header.Get("Authorization"))
		require.NoError(t, json.NewDecoder(r.Body).Decode(&receivedPayload))
		resp := lfsBatchResponse{
			Transfer: "basic",
			Objects: []lfsBatchObject{
				{OID: oid, Size: 42, Actions: map[string]lfsBatchAction{
					"upload": {Href: "https://example.com/upload"},
				}},
			},
		}
		w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
		require.NoError(t, json.NewEncoder(w).Encode(resp))
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL + "/lfs")
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL, AuthHeader: "Basic dTpw"}
	objects := []lfsUploadObject{{OID: oid, Size: 42}}

	got, err := sendLFSBatchRequest(server.Client(), endpoint, "refs/heads/main", objects)
	require.NoError(t, err)
	require.Len(t, got.Objects, 1)
	assert.Equal(t, oid, got.Objects[0].OID)
	assert.Contains(t, got.Objects[0].Actions, "upload")
	assert.Equal(t, "upload", receivedPayload.Operation)
	require.NotNil(t, receivedPayload.Ref)
	assert.Equal(t, "refs/heads/main", receivedPayload.Ref.Name)
}

// TestSendLFSBatchRequestNoRef ensures no ref field is sent when refName is empty.
func TestSendLFSBatchRequestNoRef(t *testing.T) {
	var receivedPayload lfsBatchRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, json.NewDecoder(r.Body).Decode(&receivedPayload))
		resp := lfsBatchResponse{Objects: []lfsBatchObject{}}
		w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
		require.NoError(t, json.NewEncoder(w).Encode(resp))
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	_, err = sendLFSBatchRequest(server.Client(), lfsEndpoint{BaseURL: parsedURL}, "", nil)
	require.NoError(t, err)
	assert.Nil(t, receivedPayload.Ref)
}

// TestSendLFSBatchRequestServerError surfaces non-2xx status as an error.
func TestSendLFSBatchRequestServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	_, err = sendLFSBatchRequest(server.Client(), lfsEndpoint{BaseURL: parsedURL}, "", nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "500")
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

// TestProcessLFSBatchObjectUploadAndVerify exercises the happy path where batch returns both actions.
func TestProcessLFSBatchObjectUploadAndVerify(t *testing.T) {
	repo := testInitRepo(t)
	gitDir, err := resolveGitDir(repo)
	require.NoError(t, err)

	oid := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	objectBody := []byte("test-payload")
	testWriteFile(t, filepath.Join(gitDir, "lfs", "objects", oid[:2], oid[2:4], oid), objectBody, 0o644)

	var mu sync.Mutex
	uploaded := []byte{}
	verified := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPut:
			body, readErr := io.ReadAll(r.Body)
			require.NoError(t, readErr)
			mu.Lock()
			uploaded = body
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodPost:
			mu.Lock()
			verified = true
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL}

	err = processLFSBatchObject(server.Client(), gitDir, endpoint,
		lfsUploadObject{OID: oid, Size: int64(len(objectBody))},
		lfsBatchObject{
			OID:  oid,
			Size: int64(len(objectBody)),
			Actions: map[string]lfsBatchAction{
				"upload": {Href: server.URL + "/upload/" + oid},
				"verify": {Href: server.URL + "/verify/" + oid},
			},
		},
	)
	require.NoError(t, err)
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, objectBody, uploaded)
	assert.True(t, verified)
}

// TestProcessLFSBatchObjectError returns the object-level error from the batch response.
func TestProcessLFSBatchObjectError(t *testing.T) {
	err := processLFSBatchObject(http.DefaultClient, "", lfsEndpoint{},
		lfsUploadObject{OID: "x"},
		lfsBatchObject{
			OID:   "x",
			Error: &lfsBatchError{Code: 404, Message: "not found"},
		},
	)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

// TestProcessLFSBatchObjectFallback verifies the HEAD-check + direct-upload fallback
// when the batch response omits an upload action.
func TestProcessLFSBatchObjectFallback(t *testing.T) {
	repo := testInitRepo(t)
	gitDir, err := resolveGitDir(repo)
	require.NoError(t, err)

	oid := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	objectBody := []byte("fallback-payload")
	testWriteFile(t, filepath.Join(gitDir, "lfs", "objects", oid[:2], oid[2:4], oid), objectBody, 0o644)

	var mu sync.Mutex
	directUploaded := []byte{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodHead:
			w.WriteHeader(http.StatusNotFound)
		case r.Method == http.MethodPut:
			body, readErr := io.ReadAll(r.Body)
			require.NoError(t, readErr)
			mu.Lock()
			directUploaded = body
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL}

	err = processLFSBatchObject(server.Client(), gitDir, endpoint,
		lfsUploadObject{OID: oid, Size: int64(len(objectBody))},
		lfsBatchObject{OID: oid, Size: int64(len(objectBody)), Actions: map[string]lfsBatchAction{}},
	)
	require.NoError(t, err)
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, objectBody, directUploaded)
}

// TestProcessLFSBatchObjectSkipsWhenPresent confirms no upload happens when HEAD reports the object exists.
func TestProcessLFSBatchObjectSkipsWhenPresent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodHead:
			w.WriteHeader(http.StatusOK)
		default:
			t.Fatal("unexpected request", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL}
	oid := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

	err = processLFSBatchObject(server.Client(), "/unused", endpoint,
		lfsUploadObject{OID: oid, Size: 1},
		lfsBatchObject{OID: oid, Size: 1, Actions: map[string]lfsBatchAction{}},
	)
	require.NoError(t, err)
}

// TestUploadMissingLFSObjects uploads missing objects and performs verify when server requests both actions.
func TestUploadMissingLFSObjects(t *testing.T) {
	repo := testInitRepo(t)
	gitDir, err := resolveGitDir(repo)
	require.NoError(t, err)

	oid := "2222222222222222222222222222222222222222222222222222222222222222"
	objectBody := []byte("encrypted-object-body")
	localObjectPath := filepath.Join(gitDir, "lfs", "objects", oid[:2], oid[2:4], oid)
	testWriteFile(t, localObjectPath, objectBody, 0o644)

	var mu sync.Mutex
	uploaded := []byte{}
	verifyCalls := 0
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/batch":
			require.Equal(t, http.MethodPost, r.Method)
			require.Equal(t, "application/vnd.git-lfs+json", r.Header.Get("Accept"))
			require.Equal(t, "application/vnd.git-lfs+json", r.Header.Get("Content-Type"))
			var payload lfsBatchRequest
			require.NoError(t, json.NewDecoder(r.Body).Decode(&payload))
			require.Equal(t, "upload", payload.Operation)
			require.Len(t, payload.Objects, 1)
			response := lfsBatchResponse{
				Objects: []lfsBatchObject{
					{
						OID:  oid,
						Size: int64(len(objectBody)),
						Actions: map[string]lfsBatchAction{
							"upload": {
								Href: server.URL + "/upload/" + oid,
								Header: map[string]string{
									"X-Upload-Token": "test-upload",
								},
							},
							"verify": {
								Href: server.URL + "/verify/" + oid,
								Header: map[string]string{
									"X-Verify-Token": "test-verify",
								},
							},
						},
					},
				},
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.URL.Path == "/upload/"+oid:
			require.Equal(t, http.MethodPut, r.Method)
			require.Equal(t, "test-upload", r.Header.Get("X-Upload-Token"))
			body, readErr := io.ReadAll(r.Body)
			require.NoError(t, readErr)
			mu.Lock()
			uploaded = append([]byte{}, body...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/verify/"+oid:
			require.Equal(t, http.MethodPost, r.Method)
			require.Equal(t, "test-verify", r.Header.Get("X-Verify-Token"))
			var verifyPayload lfsUploadObject
			require.NoError(t, json.NewDecoder(r.Body).Decode(&verifyPayload))
			require.Equal(t, oid, verifyPayload.OID)
			require.EqualValues(t, len(objectBody), verifyPayload.Size)
			mu.Lock()
			verifyCalls += 1
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL}
	err = uploadMissingLFSObjects(
		server.Client(),
		repo,
		endpoint,
		"refs/heads/main",
		[]lfsUploadObject{{OID: oid, Size: int64(len(objectBody))}},
	)
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, objectBody, uploaded)
	assert.Equal(t, 1, verifyCalls)
}

// TestUploadMissingLFSObjectsFallbackToDirectUpload handles stale metadata where batch says present but bytes are missing.
func TestUploadMissingLFSObjectsFallbackToDirectUpload(t *testing.T) {
	repo := testInitRepo(t)
	gitDir, err := resolveGitDir(repo)
	require.NoError(t, err)

	oid := "3333333333333333333333333333333333333333333333333333333333333333"
	objectBody := []byte("encrypted-object-body-fallback")
	localObjectPath := filepath.Join(gitDir, "lfs", "objects", oid[:2], oid[2:4], oid)
	testWriteFile(t, localObjectPath, objectBody, 0o644)

	var mu sync.Mutex
	headCalls := 0
	directPutCalls := 0
	uploaded := []byte{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/batch":
			require.Equal(t, http.MethodPost, r.Method)
			var payload lfsBatchRequest
			require.NoError(t, json.NewDecoder(r.Body).Decode(&payload))
			require.Len(t, payload.Objects, 1)
			// Return no upload action to simulate stale metadata that claims object already exists.
			response := lfsBatchResponse{
				Objects: []lfsBatchObject{
					{
						OID:     oid,
						Size:    int64(len(objectBody)),
						Actions: map[string]lfsBatchAction{},
					},
				},
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.URL.Path == "/objects/"+oid && r.Method == http.MethodHead:
			mu.Lock()
			headCalls += 1
			mu.Unlock()
			// Simulate stale metadata: HEAD reports content missing.
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/objects/"+oid && r.Method == http.MethodPut:
			body, readErr := io.ReadAll(r.Body)
			require.NoError(t, readErr)
			mu.Lock()
			directPutCalls += 1
			uploaded = append([]byte{}, body...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	endpoint := lfsEndpoint{BaseURL: parsedURL}
	err = uploadMissingLFSObjects(
		server.Client(),
		repo,
		endpoint,
		"refs/heads/main",
		[]lfsUploadObject{{OID: oid, Size: int64(len(objectBody))}},
	)
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, 1, headCalls)
	assert.Equal(t, 1, directPutCalls)
	assert.Equal(t, objectBody, uploaded)
}
