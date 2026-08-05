package decryptproxy

import (
	"encoding/base64"
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
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// lfsTestServerUpstream reproduces the exact behavior of the git-lfs-test-server
// deployment this project runs in docker-compose. Its quirks are the reason
// decryptd cannot treat upstream object reads as cheap:
//
//   - HEAD responses carry no Content-Length, so any size lookup that relies on
//     HEAD silently degrades into a second request.
//   - HEAD still runs io.Copy over the whole file. Go discards the body for
//     HEAD, but the handler keeps pulling every byte off disk, so a HEAD costs a
//     full-object read on the server.
//   - Range requests only parse the start offset. The end is ignored and the
//     server always streams to EOF.
//
// The earlier fixtures in server_test.go model a well-behaved upstream, which is
// why the request amplification against the real server went unnoticed.
type lfsTestServerUpstream struct {
	server *httptest.Server

	mu           sync.Mutex
	requests     []upstreamRequest
	diskBytes    int64
	handlersDone sync.WaitGroup
}

// upstreamRequest records one observed upstream call so tests can assert on the
// request pattern decryptd generates, not just on the bytes it returns.
type upstreamRequest struct {
	Method string
	Accept string
	Range  string
}

// newLfsTestServerUpstream serves payload with git-lfs-test-server semantics and
// meters how many bytes the handler reads off disk.
func newLfsTestServerUpstream(t *testing.T, payload []byte) *lfsTestServerUpstream {
	t.Helper()

	dir := t.TempDir()
	path := filepath.Join(dir, "object")
	require.NoError(t, os.WriteFile(path, payload, 0o600))

	upstream := &lfsTestServerUpstream{}
	upstream.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstream.handlersDone.Add(1)
		defer upstream.handlersDone.Done()

		upstream.mu.Lock()
		upstream.requests = append(upstream.requests, upstreamRequest{
			Method: r.Method,
			Accept: r.Header.Get("Accept"),
			Range:  r.Header.Get("Range"),
		})
		upstream.mu.Unlock()

		// The metadata route is selected by Accept, exactly like lfs-test-server's
		// MetaMatcher. It answers from the metadata DB without touching content.
		if strings.HasPrefix(r.Header.Get("Accept"), "application/vnd.git-lfs+json") {
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"oid":  "test-oid",
				"size": len(payload),
			})
			return
		}

		file, err := os.Open(path)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		defer file.Close()

		var fromByte int64
		status := http.StatusOK
		if rangeHeader := r.Header.Get("Range"); rangeHeader != "" {
			var from int64
			if _, err := fmt.Sscanf(rangeHeader, "bytes=%d-", &from); err == nil {
				status = http.StatusPartialContent
				fromByte = from
				w.Header().Set("Content-Range", fmt.Sprintf(
					"bytes %d-%d/%d", fromByte, int64(len(payload))-1, int64(len(payload))-fromByte))
			}
		}
		if fromByte > 0 {
			if _, err := file.Seek(fromByte, io.SeekStart); err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
		}

		w.WriteHeader(status)
		// Always streams to EOF, ignoring any range end.
		_, _ = io.Copy(w, meteredReader{reader: file, upstream: upstream})
	}))
	t.Cleanup(upstream.server.Close)
	return upstream
}

// meteredReader counts bytes pulled off disk, which is the cost that dominates
// on the Raspberry Pi's mechanical USB drive.
type meteredReader struct {
	reader   io.Reader
	upstream *lfsTestServerUpstream
}

func (m meteredReader) Read(p []byte) (int, error) {
	n, err := m.reader.Read(p)
	m.upstream.mu.Lock()
	m.upstream.diskBytes += int64(n)
	m.upstream.mu.Unlock()
	return n, err
}

// observed returns the recorded calls after in-flight handlers finish, so
// background disk reads triggered by HEAD are attributed before assertions run.
func (u *lfsTestServerUpstream) observed() ([]upstreamRequest, int64) {
	u.handlersDone.Wait()
	u.mu.Lock()
	defer u.mu.Unlock()
	return append([]upstreamRequest(nil), u.requests...), u.diskBytes
}

func (u *lfsTestServerUpstream) reset() {
	u.handlersDone.Wait()
	u.mu.Lock()
	defer u.mu.Unlock()
	u.requests = nil
	u.diskBytes = 0
}

// TestServeRangeAgainstLfsTestServerDoesNotReadWholeObject is the regression
// guard for the pathological video start-up latency on the Raspberry Pi: playing
// a 1 GB video issued a HEAD per browser range request, and each HEAD made the
// LFS server read the entire object off a mechanical disk before the first video
// byte could be served.
//
// Serving a small range must stay proportional to the range, not to the object.
func TestServeRangeAgainstLfsTestServerDoesNotReadWholeObject(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	// 8 MiB is comfortably larger than kernel socket buffers, so a stream that
	// decryptd abandons early cannot be mistaken for a whole-object read.
	plaintext := make([]byte, 8<<20)
	for i := range plaintext {
		plaintext[i] = byte(i)
	}
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := newLfsTestServerUpstream(t, encrypted)
	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.server.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", "bytes=0-1023")

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, plaintext[:1024], rec.Body.Bytes())

	requests, diskBytes := upstream.observed()

	for _, request := range requests {
		assert.NotEqual(t, http.MethodHead, request.Method,
			"HEAD makes lfs-test-server read the whole object off disk; size must come from the metadata API")
		assert.NotEqual(t, "bytes=0-0", request.Range,
			"a bytes=0-0 probe makes lfs-test-server stream the whole object")
	}

	// Serving 1 KiB should touch chunk 0 only. httptest and kernel socket
	// buffers can pull ahead substantially on an abandoned stream (CI runners
	// have been observed near half the object), so allow up to 3/4 while still
	// failing the whole-object regression this test exists to catch.
	assert.Less(t, diskBytes, int64(len(encrypted))*3/4,
		"serving a 1 KiB range read %d of %d object bytes off disk", diskBytes, len(encrypted))
}

// TestObjectSizeComesFromLfsMetadataApi pins the mechanism that keeps start-up
// cheap: the LFS metadata API answers from the metadata DB, so decryptd learns
// the encrypted object size without provoking any content read.
func TestObjectSizeComesFromLfsMetadataApi(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := newLfsTestServerUpstream(t, encrypted)
	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.server.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, plaintext, rec.Body.Bytes())

	requests, _ := upstream.observed()
	require.NotEmpty(t, requests)
	assert.Equal(t, "application/vnd.git-lfs+json", requests[0].Accept,
		"the first upstream call must be the metadata lookup")
}

// TestObjectSizeIsCachedAcrossRequests keeps seeking responsive. A browser
// issues many range requests per playback, and re-resolving the object size on
// every one of them multiplies upstream round trips for no benefit.
func TestObjectSizeIsCachedAcrossRequests(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := make([]byte, gitcrypt.ChunkSize*2)
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := newLfsTestServerUpstream(t, encrypted)
	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.server.URL})
	require.NoError(t, err)

	serveRange := func(rangeHeader string) {
		req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
		req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
		req.Header.Set("Range", rangeHeader)
		rec := httptest.NewRecorder()
		proxy.Handler().ServeHTTP(rec, req)
		require.Equal(t, http.StatusPartialContent, rec.Code)
	}

	serveRange("bytes=0-255")
	requests, _ := upstream.observed()
	assert.Equal(t, 1, countMetadataRequests(requests),
		"the first request for an object must resolve its size once")

	upstream.reset()
	serveRange("bytes=1024-2047")

	requests, _ = upstream.observed()
	assert.Zero(t, countMetadataRequests(requests),
		"object size must be reused across range requests for the same object")
}

// countMetadataRequests reports how many LFS metadata lookups an exchange needed.
func countMetadataRequests(requests []upstreamRequest) int {
	count := 0
	for _, request := range requests {
		if strings.HasPrefix(request.Accept, "application/vnd.git-lfs+json") {
			count++
		}
	}
	return count
}

// TestVideoContentTypeIsDetected keeps direct play working in browsers, which
// refuse to treat application/octet-stream as a playable media source.
func TestVideoContentTypeIsDetected(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")

	// Minimal QuickTime/MP4 ftyp box header, as produced by iPhone recordings.
	plaintext := make([]byte, 4096)
	copy(plaintext, []byte{0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p', 'q', 't', ' ', ' '})
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := newLfsTestServerUpstream(t, encrypted)
	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.server.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "video/quicktime", rec.Header().Get("Content-Type"))
}
