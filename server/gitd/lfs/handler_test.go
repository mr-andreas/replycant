package lfs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	metaMediaType    = "application/vnd.git-lfs+json"
	contentMediaType = "application/vnd.git-lfs"
)

// newTestHandler builds a writable LFS handler rooted at a temp store.
func newTestHandler(t *testing.T) (*Handler, *Store) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)
	return NewHandler(store, "/lfs"), store
}

// putObject stores content under its SHA-256 OID for download/range fixtures.
func putObject(t *testing.T, store *Store, content []byte) string {
	t.Helper()
	oid := oidFor(content)
	require.NoError(t, store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content)))
	return oid
}

// TestHandler_BatchUploadActions covers the upload negotiation contract clients
// rely on: missing objects get an upload href under /lfs, present ones get none.
func TestHandler_BatchUploadActions(t *testing.T) {
	h, store := newTestHandler(t)
	present := putObject(t, store, []byte("present-upload"))
	missingContent := []byte("missing-upload")
	missing := oidFor(missingContent)

	body := map[string]any{
		"operation": "upload",
		"transfers": []string{"basic"},
		"objects": []map[string]any{
			{"oid": present, "size": len("present-upload")},
			{"oid": missing, "size": len(missingContent)},
		},
	}
	raw, err := json.Marshal(body)
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodPost, "https://git.example:8443/lfs/objects/batch", bytes.NewReader(raw))
	req.Header.Set("Accept", metaMediaType)
	req.Header.Set("Content-Type", metaMediaType)
	req.Host = "git.example:8443"
	req.TLS = &tls.ConnectionState{}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	assert.Contains(t, rr.Header().Get("Content-Type"), metaMediaType)

	var resp batchResponse
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &resp))
	assert.Equal(t, "basic", resp.Transfer)
	require.Len(t, resp.Objects, 2)

	byOID := map[string]batchObjectResponse{}
	for _, obj := range resp.Objects {
		byOID[obj.OID] = obj
	}
	assert.Empty(t, byOID[present].Actions)
	require.NotNil(t, byOID[missing].Actions)
	upload := byOID[missing].Actions["upload"]
	require.NotNil(t, upload)
	assert.Equal(t, "https://git.example:8443/lfs/objects/"+missing, upload.Href)
	assert.Nil(t, byOID[missing].Actions["verify"])
}

// TestHandler_BatchDownloadActions covers download negotiation including the
// 404 error shape for missing objects.
func TestHandler_BatchDownloadActions(t *testing.T) {
	h, store := newTestHandler(t)
	present := putObject(t, store, []byte("present-download"))
	missing := strings.Repeat("a", 64)

	body := map[string]any{
		"operation": "download",
		"transfers": []string{"basic"},
		"objects": []map[string]any{
			{"oid": present, "size": len("present-download")},
			{"oid": missing, "size": 1},
		},
	}
	raw, err := json.Marshal(body)
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodPost, "http://host/lfs/objects/batch", bytes.NewReader(raw))
	req.Header.Set("Accept", metaMediaType)
	req.Header.Set("Content-Type", metaMediaType)
	req.Host = "host"
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	var resp batchResponse
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &resp))
	require.Len(t, resp.Objects, 2)

	byOID := map[string]batchObjectResponse{}
	for _, obj := range resp.Objects {
		byOID[obj.OID] = obj
	}
	require.NotNil(t, byOID[present].Actions["download"])
	assert.Equal(t, "http://host/lfs/objects/"+present, byOID[present].Actions["download"].Href)
	require.NotNil(t, byOID[missing].Error)
	assert.Equal(t, 404, byOID[missing].Error.Code)
}

// TestHandler_UploadDownloadRoundTrip verifies batch upload → PUT → GET.
func TestHandler_UploadDownloadRoundTrip(t *testing.T) {
	h, _ := newTestHandler(t)
	content := []byte("round-trip-bytes")
	oid := oidFor(content)

	batchBody, err := json.Marshal(map[string]any{
		"operation": "upload",
		"transfers": []string{"basic"},
		"objects":   []map[string]any{{"oid": oid, "size": len(content)}},
	})
	require.NoError(t, err)
	batchReq := httptest.NewRequest(http.MethodPost, "/lfs/objects/batch", bytes.NewReader(batchBody))
	batchReq.Header.Set("Accept", metaMediaType)
	batchReq.Header.Set("Content-Type", metaMediaType)
	batchReq.Host = "example.test"
	batchRR := httptest.NewRecorder()
	h.ServeHTTP(batchRR, batchReq)
	require.Equal(t, http.StatusOK, batchRR.Code)

	putReq := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, bytes.NewReader(content))
	putReq.Header.Set("Accept", contentMediaType)
	putReq.ContentLength = int64(len(content))
	putRR := httptest.NewRecorder()
	h.ServeHTTP(putRR, putReq)
	require.Equal(t, http.StatusOK, putRR.Code)

	getReq := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
	getReq.Header.Set("Accept", contentMediaType)
	getRR := httptest.NewRecorder()
	h.ServeHTTP(getRR, getReq)
	require.Equal(t, http.StatusOK, getRR.Code)
	assert.Equal(t, content, getRR.Body.Bytes())
}

// TestHandler_PutExistingAnswersWithoutDrainingBody ensures duplicate uploads
// return 200 before consuming the request body.
func TestHandler_PutExistingAnswersWithoutDrainingBody(t *testing.T) {
	h, store := newTestHandler(t)
	content := []byte("dup-upload")
	oid := putObject(t, store, content)

	body := &countingReader{r: bytes.NewReader(bytes.Repeat([]byte("z"), 1024))}
	req := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, body)
	req.Header.Set("Accept", contentMediaType)
	req.ContentLength = 1024
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	assert.Zero(t, body.n, "handler must not drain body for existing objects")

	f, _, err := store.Open(oid)
	require.NoError(t, err)
	defer f.Close()
	got, err := io.ReadAll(f)
	require.NoError(t, err)
	assert.Equal(t, content, got)
}

// TestHandler_PutInFlightConflictAnswers409WithoutDrainingBody ensures a second
// PUT for an OID already being written fails fast with 409 and never reads the
// body, so clients can abort and upload something else.
func TestHandler_PutInFlightConflictAnswers409WithoutDrainingBody(t *testing.T) {
	h, store := newTestHandler(t)
	content := bytes.Repeat([]byte("c"), 64*1024)
	oid := oidFor(content)

	started := make(chan struct{}, 1)
	release := make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- store.Put(context.Background(), oid, int64(len(content)), &gateReader{
			r:       bytes.NewReader(content),
			started: started,
			release: release,
		})
	}()

	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("first writer did not start streaming")
	}

	body := &countingReader{r: bytes.NewReader(content)}
	req := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, body)
	req.Header.Set("Accept", contentMediaType)
	req.ContentLength = int64(len(content))
	rr := httptest.NewRecorder()

	handlerDone := make(chan struct{})
	go func() {
		defer close(handlerDone)
		h.ServeHTTP(rr, req)
	}()

	select {
	case <-handlerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("conflicted PUT blocked instead of failing fast")
	}

	require.Equal(t, http.StatusConflict, rr.Code)
	assert.Contains(t, rr.Header().Get("Content-Type"), metaMediaType)
	var payload struct {
		Message string `json:"message"`
	}
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &payload))
	assert.Contains(t, payload.Message, "in progress")
	assert.Zero(t, atomic.LoadInt64(&body.n), "conflicted PUT must not consume body")
	assert.Zero(t, atomic.LoadInt64(&body.reads))

	close(release)
	require.NoError(t, <-firstDone)
	assert.True(t, store.Exists(oid))
}

// TestHandler_MetadataJSON returns size without opening object content beyond Stat.
func TestHandler_MetadataJSON(t *testing.T) {
	h, store := newTestHandler(t)
	content := []byte("meta-object")
	oid := putObject(t, store, content)

	req := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
	req.Header.Set("Accept", metaMediaType)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	require.Equal(t, http.StatusOK, rr.Code)
	assert.Contains(t, rr.Header().Get("Content-Type"), metaMediaType)
	var payload struct {
		OID  string `json:"oid"`
		Size int64  `json:"size"`
	}
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &payload))
	assert.Equal(t, oid, payload.OID)
	assert.Equal(t, int64(len(content)), payload.Size)
}

// TestHandler_RejectsMalformedOIDs keeps path traversal and bad digests out.
func TestHandler_RejectsMalformedOIDs(t *testing.T) {
	h, _ := newTestHandler(t)
	bad := []string{
		"abc",
		strings.Repeat("A", 64),
		strings.Repeat("0", 63) + "g",
		"../" + strings.Repeat("0", 61),
		strings.Repeat("0", 32) + "/" + strings.Repeat("0", 31),
	}
	for _, oid := range bad {
		req := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
		req.Header.Set("Accept", contentMediaType)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		assert.Equal(t, http.StatusBadRequest, rr.Code, "oid %q", oid)
	}
}

// TestHandler_DeleteMethodNotAllowed documents that clients cannot remove objects.
func TestHandler_DeleteMethodNotAllowed(t *testing.T) {
	h, store := newTestHandler(t)
	oid := putObject(t, store, []byte("no-delete"))

	req := httptest.NewRequest(http.MethodDelete, "/lfs/objects/"+oid, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	assert.Equal(t, http.StatusMethodNotAllowed, rr.Code)
	assert.True(t, store.Exists(oid))
}

// TestHandler_ReadOnlyRejectsMutations protects the internal listener.
func TestHandler_ReadOnlyRejectsMutations(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)
	h := NewReadOnlyHandler(store, "/lfs")
	content := []byte("readonly")
	oid := oidFor(content)

	batchBody, err := json.Marshal(map[string]any{
		"operation": "upload",
		"objects":   []map[string]any{{"oid": oid, "size": len(content)}},
	})
	require.NoError(t, err)
	batchReq := httptest.NewRequest(http.MethodPost, "/lfs/objects/batch", bytes.NewReader(batchBody))
	batchReq.Header.Set("Accept", metaMediaType)
	batchReq.Header.Set("Content-Type", metaMediaType)
	batchRR := httptest.NewRecorder()
	h.ServeHTTP(batchRR, batchReq)
	assert.Equal(t, http.StatusMethodNotAllowed, batchRR.Code)

	putReq := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, bytes.NewReader(content))
	putRR := httptest.NewRecorder()
	h.ServeHTTP(putRR, putReq)
	assert.Equal(t, http.StatusMethodNotAllowed, putRR.Code)
	assert.False(t, store.Exists(oid))
}

// TestHandler_BoundedMemoryStreamsLargeObjects ensures PUT/GET do not buffer the
// whole object in heap.
func TestHandler_BoundedMemoryStreamsLargeObjects(t *testing.T) {
	if testing.Short() {
		t.Skip("large allocation check")
	}
	h, _ := newTestHandler(t)
	const size = 128 << 20
	oid := sha256OfSize(size)

	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	putReq := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, &zeroReader{n: size})
	putReq.Header.Set("Accept", contentMediaType)
	putReq.ContentLength = size
	putRR := httptest.NewRecorder()
	h.ServeHTTP(putRR, putReq)
	require.Equal(t, http.StatusOK, putRR.Code)

	getReq := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
	getReq.Header.Set("Accept", contentMediaType)
	getReq.Header.Set("Range", "bytes=0-1023")
	getRR := httptest.NewRecorder()
	h.ServeHTTP(getRR, getReq)
	require.Equal(t, http.StatusPartialContent, getRR.Code)
	require.Len(t, getRR.Body.Bytes(), 1024)

	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	growth := int64(after.HeapAlloc) - int64(before.HeapAlloc)
	if growth < 0 {
		growth = 0
	}
	assert.Less(t, growth, int64(16<<20), "heap growth %d should stay far below object size", growth)
}

// TestHandler_RangeSemantics covers the byte-range behaviour video seeking and
// decryptd depend on, including the end-bound regression lfs-test-server had.
func TestHandler_RangeSemantics(t *testing.T) {
	content := make([]byte, 100)
	for i := range content {
		content[i] = byte(i)
	}

	run := func(t *testing.T, h http.Handler, store *Store) {
		t.Helper()
		oid := putObject(t, store, content)

		t.Run("bounded range honors end", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=10-19")
			require.Equal(t, http.StatusPartialContent, rr.Code)
			assert.Equal(t, "bytes", rr.Header().Get("Accept-Ranges"))
			assert.Equal(t, "bytes 10-19/100", rr.Header().Get("Content-Range"))
			assert.Equal(t, content[10:20], rr.Body.Bytes())
			assert.Equal(t, `"`+oid+`"`, rr.Header().Get("ETag"))
			assert.Equal(t, "public, max-age=31536000, immutable", rr.Header().Get("Cache-Control"))
			assert.Equal(t, "application/octet-stream", rr.Header().Get("Content-Type"))
		})

		t.Run("open ended", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=5-")
			require.Equal(t, http.StatusPartialContent, rr.Code)
			assert.Equal(t, content[5:], rr.Body.Bytes())
		})

		t.Run("suffix", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=-5")
			require.Equal(t, http.StatusPartialContent, rr.Code)
			assert.Equal(t, content[95:], rr.Body.Bytes())
		})

		t.Run("mid object seek", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=50-59")
			require.Equal(t, http.StatusPartialContent, rr.Code)
			assert.Equal(t, content[50:60], rr.Body.Bytes())
		})

		t.Run("multipart", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=0-1,10-11")
			require.Equal(t, http.StatusPartialContent, rr.Code)
			mediaType, params, err := mime.ParseMediaType(rr.Header().Get("Content-Type"))
			require.NoError(t, err)
			require.Equal(t, "multipart/byteranges", mediaType)
			mr := multipart.NewReader(rr.Body, params["boundary"])
			part1, err := mr.NextPart()
			require.NoError(t, err)
			b1, err := io.ReadAll(part1)
			require.NoError(t, err)
			assert.Equal(t, content[0:2], b1)
			part2, err := mr.NextPart()
			require.NoError(t, err)
			b2, err := io.ReadAll(part2)
			require.NoError(t, err)
			assert.Equal(t, content[10:12], b2)
		})

		t.Run("unsatisfiable", func(t *testing.T) {
			rr := doRange(t, h, oid, "bytes=1000-1001")
			require.Equal(t, http.StatusRequestedRangeNotSatisfiable, rr.Code)
			assert.Equal(t, "bytes */100", rr.Header().Get("Content-Range"))
		})

		t.Run("malformed range ignored", func(t *testing.T) {
			rr := doRange(t, h, oid, "nonsense")
			require.Equal(t, http.StatusOK, rr.Code)
			assert.Equal(t, content, rr.Body.Bytes())
		})

		t.Run("head", func(t *testing.T) {
			req := httptest.NewRequest(http.MethodHead, "/lfs/objects/"+oid, nil)
			req.Header.Set("Accept", contentMediaType)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, req)
			require.Equal(t, http.StatusOK, rr.Code)
			assert.Equal(t, "bytes", rr.Header().Get("Accept-Ranges"))
			assert.Equal(t, "100", rr.Header().Get("Content-Length"))
			assert.Empty(t, rr.Body.Bytes())
			assert.Equal(t, "public, max-age=31536000, immutable", rr.Header().Get("Cache-Control"))
		})

		t.Run("etag conditional", func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
			req.Header.Set("Accept", contentMediaType)
			req.Header.Set("If-None-Match", `"`+oid+`"`)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, req)
			assert.Equal(t, http.StatusNotModified, rr.Code)
		})

		t.Run("if-range stale validator", func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
			req.Header.Set("Accept", contentMediaType)
			req.Header.Set("Range", "bytes=0-9")
			req.Header.Set("If-Range", `"deadbeef"`)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, req)
			assert.Equal(t, http.StatusOK, rr.Code)
			assert.Equal(t, content, rr.Body.Bytes())
		})
	}

	t.Run("writable", func(t *testing.T) {
		h, store := newTestHandler(t)
		run(t, h, store)
	})
	t.Run("read-only", func(t *testing.T) {
		store, err := NewStore(t.TempDir())
		require.NoError(t, err)
		run(t, NewReadOnlyHandler(store, "/lfs"), store)
	})
}

// TestHandler_LargeRangeBoundedAllocation ensures a mid-file range on a large
// object does not pull the whole object into memory.
func TestHandler_LargeRangeBoundedAllocation(t *testing.T) {
	if testing.Short() {
		t.Skip("large allocation check")
	}
	h, _ := newTestHandler(t)
	const size = 64 << 20
	oid := sha256OfSize(size)

	putReq := httptest.NewRequest(http.MethodPut, "/lfs/objects/"+oid, &zeroReader{n: size})
	putReq.ContentLength = size
	putReq.Header.Set("Accept", contentMediaType)
	putRR := httptest.NewRecorder()
	h.ServeHTTP(putRR, putReq)
	require.Equal(t, http.StatusOK, putRR.Code)

	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	rr := doRange(t, h, oid, fmt.Sprintf("bytes=%d-%d", size/2, size/2+1023))
	require.Equal(t, http.StatusPartialContent, rr.Code)
	require.Len(t, rr.Body.Bytes(), 1024)

	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	growth := int64(after.HeapAlloc) - int64(before.HeapAlloc)
	if growth < 0 {
		growth = 0
	}
	assert.Less(t, growth, int64(8<<20), "range read heap growth %d", growth)
}

func doRange(t *testing.T, h http.Handler, oid, rangeHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/lfs/objects/"+oid, nil)
	req.Header.Set("Accept", contentMediaType)
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

// sha256OfSize returns the OID of size zero bytes without allocating that buffer.
func sha256OfSize(size int64) string {
	h := sha256.New()
	buf := make([]byte, 32*1024)
	remaining := size
	for remaining > 0 {
		n := int64(len(buf))
		if n > remaining {
			n = remaining
		}
		_, _ = h.Write(buf[:n])
		remaining -= n
	}
	return hex.EncodeToString(h.Sum(nil))
}

// zeroReader streams size zero bytes for large upload tests without allocating
// the full object in memory.
type zeroReader struct {
	n int64
}

func (z *zeroReader) Read(p []byte) (int, error) {
	if z.n <= 0 {
		return 0, io.EOF
	}
	n := len(p)
	if int64(n) > z.n {
		n = int(z.n)
	}
	clear(p[:n])
	z.n -= int64(n)
	return n, nil
}
