package gitd

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/mr-andreas/replycant/server/gitd/gittest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type mockAuthenticator struct {
	AuthErr      error
	AuthUsername string
}

func (a *mockAuthenticator) Authenticate(clientCert *x509.Certificate) (string, error) {
	return a.AuthUsername, a.AuthErr
}

// setupHookBinaryForTests ensures NewServer can install the pre-receive hook in test environments.
func setupHookBinaryForTests(t *testing.T) {
	t.Helper()

	binDir := t.TempDir()
	binPath := filepath.Join(binDir, "lfs-prereceive")
	err := os.WriteFile(binPath, []byte("#!/bin/sh\nexit 0\n"), 0755)
	require.NoError(t, err)

	currentPath := os.Getenv("PATH")
	joined := binDir
	if currentPath != "" {
		joined = binDir + string(os.PathListSeparator) + currentPath
	}
	t.Setenv("PATH", joined)
}

// Tests that ValidateRepository accepts a bare git repository.
func TestValidateRepository_BareRepo(t *testing.T) {
	tmpDir := t.TempDir()

	_, err := git.PlainInit(tmpDir, true)
	require.NoError(t, err)

	err = ValidateRepository(tmpDir)
	assert.NoError(t, err)
}

// Tests that ValidateRepository rejects a non-bare git repository.
func TestValidateRepository_NonBareRepo(t *testing.T) {
	tmpDir := t.TempDir()

	_, err := git.PlainInit(tmpDir, false)
	require.NoError(t, err)

	err = ValidateRepository(tmpDir)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "not a bare repository")
}

// Tests that ValidateRepository rejects a non-existent path.
func TestValidateRepository_NonExistent(t *testing.T) {
	err := ValidateRepository("/nonexistent/path/to/repo")

	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid git repository")
}

// Tests that ValidateRepository rejects an empty directory.
func TestValidateRepository_EmptyDirectory(t *testing.T) {
	tmpDir := t.TempDir()

	err := ValidateRepository(tmpDir)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid git repository")
}

// Tests that ValidateRepository rejects a regular file.
func TestValidateRepository_RegularFile(t *testing.T) {
	tmpFile := filepath.Join(t.TempDir(), "not-a-repo")
	err := os.WriteFile(tmpFile, []byte("not a repo"), 0644)
	require.NoError(t, err)

	err = ValidateRepository(tmpFile)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid git repository")
}

// Tests that NewServer rejects an invalid repository path.
func TestNewServer_InvalidRepo(t *testing.T) {
	_, err := NewServer(&mockAuthenticator{}, ServerConfig{RepoPath: "/nonexistent/path/to/repo"})

	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid git repository")
}

// Tests that git-http-backend can be located on the system.
func TestFindGitHttpBackend(t *testing.T) {
	path, err := findGitHttpBackend()

	// Skip test if git is not installed
	if err != nil {
		t.Skip("git-http-backend not found, skipping test")
	}

	require.NoError(t, err)
	assert.NotEmpty(t, path)

	// Verify the file exists and is executable
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.False(t, info.IsDir())
}

// Tests HTTP request handler with authentication.
func TestServer_HandleGitRequest_Authenticated(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey

	cert := testCtx.CreateTestCertificate(t, pubKey, privKey)

	server, err := NewServer(&mockAuthenticator{}, ServerConfig{RepoPath: testRepo.BareRepo})
	require.NoError(t, err)

	// Create test request with client certificate
	req := httptest.NewRequest("GET", "/info/refs?service=git-upload-pack", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
}

// Tests HTTP request handler without client certificate.
func TestServer_HandleGitRequest_NoClientCert(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)

	testRepo := testCtx.CreateTestRepo(t)

	mockAuthenticator := &mockAuthenticator{}

	server, err := NewServer(mockAuthenticator, ServerConfig{RepoPath: testRepo.BareRepo})
	require.NoError(t, err)

	// Create test request without client certificate
	req := httptest.NewRequest("GET", "/info/refs", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Contains(t, w.Body.String(), "Client certificate required")
}

// Tests HTTP request handler with unauthorized client certificate.
func TestServer_HandleGitRequest_Unauthorized(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	mockAuthenticator := &mockAuthenticator{
		AuthErr: auth.ErrUnauthorized,
	}

	server, err := NewServer(mockAuthenticator, ServerConfig{RepoPath: testRepo.BareRepo})
	require.NoError(t, err)

	// Create client cert with unauthorized key
	clientPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	clientPubKey := &clientPrivKey.PublicKey
	clientCert := testCtx.CreateTestCertificate(t, clientPubKey, clientPrivKey)

	req := httptest.NewRequest("GET", "/info/refs", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{clientCert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Contains(t, w.Body.String(), "Authentication failed")
}

// TestNewServer_InstallsPreReceiveHook ensures push validation executes by installing a pre-receive hook.
func TestNewServer_InstallsPreReceiveHook(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	server, err := NewServer(&mockAuthenticator{}, ServerConfig{RepoPath: testRepo.BareRepo, LfsURL: "http://example.com"})
	require.NoError(t, err)
	require.NotNil(t, server)

	hookPath := filepath.Join(testRepo.BareRepo, "hooks", "pre-receive")
	info, err := os.Lstat(hookPath)
	require.NoError(t, err)
	assert.True(t, info.Mode()&os.ModeSymlink != 0)

	target, err := os.Readlink(hookPath)
	require.NoError(t, err)
	assert.True(t, strings.Contains(target, "lfs-prereceive"))
}

// Tests that /lfs routes still enforce the same client-certificate requirement as Git routes.
func TestServer_HandleLFSRequest_NoClientCert(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	server, err := NewServer(&mockAuthenticator{}, ServerConfig{RepoPath: testRepo.BareRepo, LfsURL: "http://example.com"})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/lfs/objects/abc", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Contains(t, w.Body.String(), "Client certificate required")
}

// Tests that authenticated /lfs requests are forwarded to upstream with fixed Basic auth.
func TestServer_HandleLFSRequest_ProxiesToUpstream(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	requestSeen := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestSeen = true
		require.Equal(t, "/objects/abc", r.URL.Path)
		require.Equal(t, "a=1", r.URL.RawQuery)
		require.Equal(
			t,
			"Basic "+base64.StdEncoding.EncodeToString([]byte("admin:admin")),
			r.Header.Get("Authorization"),
		)
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	server, err := NewServer(&mockAuthenticator{AuthUsername: "device-1"}, ServerConfig{
		RepoPath: testRepo.BareRepo,
		LfsURL:   "http://admin:admin@" + strings.TrimPrefix(upstream.URL, "http://"),
	})
	require.NoError(t, err)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	cert := testCtx.CreateTestCertificate(t, &privKey.PublicKey, privKey)

	req := httptest.NewRequest(http.MethodGet, "/lfs/objects/abc?a=1", nil)
	req.Host = "git.example:8443"
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	require.True(t, requestSeen)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "ok", w.Body.String())
}

// Tests that LFS batch action hrefs are rewritten to gitd /lfs URLs so follow-up calls stay mTLS-gated.
func TestServer_HandleLFSBatch_RewritesActionHrefs(t *testing.T) {
	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	upstreamURL := ""
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/objects/batch", r.URL.Path)
		w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
		_, _ = io.WriteString(w, `{
  "objects":[
    {
      "oid":"abc",
      "size":3,
      "actions":{
        "upload":{"href":"`+upstreamURL+`/objects/abc"},
        "download":{"href":"`+upstreamURL+`/objects/abc?dl=1"},
        "verify":{"href":"`+upstreamURL+`/verify/abc"}
      }
    }
  ]
}`)
	}))
	defer upstream.Close()
	upstreamURL = upstream.URL

	server, err := NewServer(&mockAuthenticator{AuthUsername: "device-1"}, ServerConfig{
		RepoPath: testRepo.BareRepo,
		LfsURL:   "http://admin:admin@" + strings.TrimPrefix(upstream.URL, "http://"),
	})
	require.NoError(t, err)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	cert := testCtx.CreateTestCertificate(t, &privKey.PublicKey, privKey)

	req := httptest.NewRequest(http.MethodPost, "/lfs/objects/batch", strings.NewReader(`{"operation":"upload"}`))
	req.Host = "git.example:8443"
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	require.Equal(t, http.StatusOK, w.Code)

	var payload map[string]any
	err = json.Unmarshal(w.Body.Bytes(), &payload)
	require.NoError(t, err)

	objects, ok := payload["objects"].([]any)
	require.True(t, ok)
	first, ok := objects[0].(map[string]any)
	require.True(t, ok)
	actions, ok := first["actions"].(map[string]any)
	require.True(t, ok)

	upload, ok := actions["upload"].(map[string]any)
	require.True(t, ok)
	download, ok := actions["download"].(map[string]any)
	require.True(t, ok)
	verify, ok := actions["verify"].(map[string]any)
	require.True(t, ok)

	assert.Equal(t, "https://git.example:8443/lfs/objects/abc", upload["href"])
	assert.Equal(t, "https://git.example:8443/lfs/objects/abc?dl=1", download["href"])
	assert.Equal(t, "https://git.example:8443/lfs/verify/abc", verify["href"])
}

// Builds a gitd server whose media routes point at the supplied upstreams so
// proxy behavior can be exercised without the full docker topology.
func newMediaProxyTestServer(t *testing.T, decryptdURL string, transcodedURL string) (*Server, *x509.Certificate) {
	t.Helper()

	setupHookBinaryForTests(t)

	testCtx := gittest.NewContext(t)
	t.Cleanup(func() { testCtx.Close(t) })
	testRepo := testCtx.CreateTestRepo(t)

	server, err := NewServer(&mockAuthenticator{AuthUsername: "device-1"}, ServerConfig{
		RepoPath:      testRepo.BareRepo,
		LfsURL:        "http://example.com",
		DecryptdURL:   decryptdURL,
		TranscodedURL: transcodedURL,
	})
	require.NoError(t, err)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	cert := testCtx.CreateTestCertificate(t, &privKey.PublicKey, privKey)

	return server, cert
}

// Tests that the media routes sit behind the same client-certificate gate as
// Git and LFS, which is the entire reason for moving them behind gitd.
func TestServer_HandleMediaRequest_NoClientCert(t *testing.T) {
	for _, path := range []string{"/decryptd/objects/abc", "/transcoded/hls/abc/1.00/playlist.m3u8"} {
		t.Run(path, func(t *testing.T) {
			server, _ := newMediaProxyTestServer(t, "http://example.com", "http://example.com")

			req := httptest.NewRequest(http.MethodGet, path, nil)
			req.TLS = &tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{},
			}

			w := httptest.NewRecorder()
			server.handleAuthenticatedRequest(w, req)

			assert.Equal(t, http.StatusUnauthorized, w.Code)
			assert.Contains(t, w.Body.String(), "Client certificate required")
		})
	}
}

// Tests that /decryptd strips its own prefix and forwards the request-scoped
// DEK headers that decryptd needs to decrypt the object.
func TestServer_HandleDecryptdRequest_ProxiesToUpstream(t *testing.T) {
	requestSeen := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestSeen = true
		require.Equal(t, "/objects/abc", r.URL.Path)
		require.Equal(t, "dek-value", r.Header.Get("X-Replycant-DEK"))
		require.Equal(t, "bytes=0-99", r.Header.Get("Range"))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.WriteString(w, "media-bytes")
	}))
	defer upstream.Close()

	server, cert := newMediaProxyTestServer(t, upstream.URL, "http://example.com")

	req := httptest.NewRequest(http.MethodGet, "/decryptd/objects/abc", nil)
	req.Header.Set("X-Replycant-DEK", "dek-value")
	req.Header.Set("Range", "bytes=0-99")
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	require.True(t, requestSeen)
	assert.Equal(t, http.StatusPartialContent, w.Code)
	assert.Equal(t, "media-bytes", w.Body.String())
}

// Tests that /transcoded strips its own prefix so HLS paths reach transcoded unchanged.
func TestServer_HandleTranscodedRequest_ProxiesToUpstream(t *testing.T) {
	requestSeen := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestSeen = true
		require.Equal(t, "/hls/abc/12.00/playlist.m3u8", r.URL.Path)
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(w, "#EXTM3U\n")
	}))
	defer upstream.Close()

	server, cert := newMediaProxyTestServer(t, "http://example.com", upstream.URL)

	req := httptest.NewRequest(http.MethodGet, "/transcoded/hls/abc/12.00/playlist.m3u8", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	require.True(t, requestSeen)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "#EXTM3U\n", w.Body.String())
}

// Tests that upstream Basic credentials embedded in a media upstream URL are
// injected server-side, so client devices never learn them.
func TestServer_HandleMediaRequest_InjectsUpstreamBasicAuth(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(
			t,
			"Basic "+base64.StdEncoding.EncodeToString([]byte("admin:admin")),
			r.Header.Get("Authorization"),
		)
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	server, cert := newMediaProxyTestServer(
		t,
		"http://admin:admin@"+strings.TrimPrefix(upstream.URL, "http://"),
		"http://example.com",
	)

	req := httptest.NewRequest(http.MethodGet, "/decryptd/objects/abc", nil)
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
}

// Tests that LFS batch href rewriting stays confined to /lfs. decryptd exposes
// an /objects/ namespace too, so an unguarded rewrite would corrupt its responses.
func TestServer_HandleDecryptdRequest_DoesNotRewriteBatchHrefs(t *testing.T) {
	body := `{"objects":[{"oid":"abc","actions":{"download":{"href":"http://elsewhere.invalid/objects/abc"}}}]}`
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	defer upstream.Close()

	server, cert := newMediaProxyTestServer(t, upstream.URL, "http://example.com")

	req := httptest.NewRequest(http.MethodPost, "/decryptd/objects/batch", strings.NewReader("{}"))
	req.Host = "git.example:8443"
	req.TLS = &tls.ConnectionState{
		PeerCertificates: []*x509.Certificate{cert},
	}

	w := httptest.NewRecorder()
	server.handleAuthenticatedRequest(w, req)

	require.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, body, w.Body.String())
}

// Tests that gitd advertises the CORS headers browsers need for ranged,
// DEK-authenticated media reads. These previously came from the lfs-cors proxy.
func TestServer_ServeHTTP_AdvertisesMediaCORSHeaders(t *testing.T) {
	server, _ := newMediaProxyTestServer(t, "http://example.com", "http://example.com")

	req := httptest.NewRequest(http.MethodOptions, "/decryptd/objects/abc", nil)
	w := httptest.NewRecorder()
	server.ServeHTTP(w, req)

	require.Equal(t, http.StatusNoContent, w.Code)
	assert.Equal(t, "*", w.Header().Get("Access-Control-Allow-Origin"))
	assert.Contains(t, w.Header().Get("Access-Control-Allow-Headers"), "X-Replycant-DEK")
	assert.NotContains(t, w.Header().Get("Access-Control-Allow-Headers"), "X-Replycant-Chunk-Size")
	assert.Contains(t, w.Header().Get("Access-Control-Expose-Headers"), "Content-Range")
	assert.Contains(t, w.Header().Get("Access-Control-Expose-Headers"), "Accept-Ranges")
}
