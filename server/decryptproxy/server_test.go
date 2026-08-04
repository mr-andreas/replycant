package decryptproxy

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseDEKHeader enforces strict DEK header validation for request safety.
func TestParseDEKHeader(t *testing.T) {
	valid := make([]byte, 32)
	encoded := base64.StdEncoding.EncodeToString(valid)

	decoded, err := parseDEKHeader(encoded)
	require.NoError(t, err)
	assert.Equal(t, 32, len(decoded))

	_, err = parseDEKHeader("")
	require.Error(t, err)

	_, err = parseDEKHeader("not-base64")
	require.Error(t, err)

	short := base64.StdEncoding.EncodeToString([]byte("short"))
	_, err = parseDEKHeader(short)
	require.Error(t, err)
}

// TestHandleObjectGetRangeSuccess verifies plaintext range output over encrypted upstream chunks.
func TestHandleObjectGetRangeSuccess(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	seenAuth := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Content reads and metadata lookups are both valid LFS routes; only
		// non-LFS Accept values would indicate a routing mistake.
		assert.Contains(t, r.Header.Get("Accept"), "application/vnd.git-lfs")
		if r.Header.Get("Authorization") == "Basic dXNlcjpwYXNz" {
			seenAuth = true
		}
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{
		UpstreamURL: strings.Replace(upstream.URL, "http://", "http://user:pass@", 1),
	})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", "bytes=5-20")

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.True(t, seenAuth)
	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, "bytes 5-20/36", rec.Header().Get("Content-Range"))
	assert.Equal(t, plaintext[5:21], rec.Body.Bytes())
}

// TestHandleObjectGetSuffixRangeSuccess verifies trailing-byte range reads used by media metadata probing.
func TestHandleObjectGetSuffixRangeSuccess(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", "bytes=-10")

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, "bytes 26-35/36", rec.Header().Get("Content-Range"))
	assert.Equal(t, plaintext[26:], rec.Body.Bytes())
}

// TestHandleObjectGetRangeSuccessWhenUpstreamIgnoresRange keeps playback viable with upstreams that return 200 full bodies.
func TestHandleObjectGetRangeSuccessWhenUpstreamIgnoresRange(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodHead:
			w.Header().Set("Content-Length", strconv.Itoa(len(encrypted)))
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			w.Header().Set("Content-Length", strconv.Itoa(len(encrypted)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(encrypted)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", "bytes=5-20")

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, "bytes 5-20/36", rec.Header().Get("Content-Range"))
	assert.Equal(t, plaintext[5:21], rec.Body.Bytes())
}

// TestHandleObjectGetFullObject verifies full-object responses stay plaintext-correct without Range.
func TestHandleObjectGetFullObject(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, plaintext, rec.Body.Bytes())
}

// TestHandleObjectHeadSuccess allows media clients to probe direct-play objects before ranged GETs.
func TestHandleObjectHeadSuccess(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodHead, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "36", rec.Header().Get("Content-Length"))
	assert.Empty(t, rec.Body.Bytes())
}

// TestHandleObjectGetStrictValidation verifies strict failures for missing and invalid headers.
func TestHandleObjectGetStrictValidation(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("0123456789abcdef")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	t.Run("missing headers", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
		rec := httptest.NewRecorder()
		proxy.Handler().ServeHTTP(rec, req)
		require.Equal(t, http.StatusBadRequest, rec.Code)
	})

	t.Run("invalid range", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
		req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
		req.Header.Set("Range", "bytes=200-300")
		rec := httptest.NewRecorder()
		proxy.Handler().ServeHTTP(rec, req)
		require.Equal(t, http.StatusRequestedRangeNotSatisfiable, rec.Code)
	})

	t.Run("no secret in error body", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
		req.Header.Set(HeaderDEK, "supersecret")
		rec := httptest.NewRecorder()
		proxy.Handler().ServeHTTP(rec, req)
		require.Equal(t, http.StatusBadRequest, rec.Code)
		assert.NotContains(t, rec.Body.String(), "supersecret")
	})
}

// TestHandleObjectGetUpstreamMetadataFailure ensures upstream HEAD failures surface as gateway errors for caller retry logic.
func TestHandleObjectGetUpstreamMetadataFailure(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			http.Error(w, "upstream unavailable", http.StatusBadGateway)
			return
		}
		http.Error(w, "unexpected", http.StatusInternalServerError)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "failed to read upstream metadata")
}

// TestHandleObjectGetMetadataFallbackViaRangeProbe keeps decryptd working with upstreams that omit HEAD content length.
func TestHandleObjectGetMetadataFallbackViaRangeProbe(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)
	probeSeen := false

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodHead:
			w.WriteHeader(http.StatusOK)
			return
		case http.MethodGet:
			if r.Header.Get("Range") == "bytes=0-0" {
				probeSeen = true
				w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", len(encrypted)))
				w.Header().Set("Content-Length", "1")
				w.WriteHeader(http.StatusPartialContent)
				_, _ = w.Write(encrypted[:1])
				return
			}
			serveRangePayload(t, w, r, encrypted)
			return
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", "bytes=5-20")

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.True(t, probeSeen)
	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, "bytes 5-20/36", rec.Header().Get("Content-Range"))
	assert.Equal(t, plaintext[5:21], rec.Body.Bytes())
}

// TestHandleObjectGetMetadataFallbackFailure keeps 502 behavior when no size metadata is recoverable.
func TestHandleObjectGetMetadataFallbackFailure(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodHead:
			w.WriteHeader(http.StatusOK)
			return
		case http.MethodGet:
			if r.Header.Get("Range") == "bytes=0-0" {
				w.WriteHeader(http.StatusPartialContent)
				_, _ = w.Write(encrypted[:1])
				return
			}
			serveRangePayload(t, w, r, encrypted)
			return
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "failed to read upstream metadata")
}

// TestHandleObjectGetDecryptFailure keeps decryptd strict when upstream bytes do not authenticate with the provided DEK.
func TestHandleObjectGetDecryptFailure(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	// Layout-valid single chunk (plaintext 16 + tag 16) that will fail GCM authentication.
	invalidEncryptedPayload := make([]byte, 32)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodHead:
			w.Header().Set("Content-Length", strconv.Itoa(len(invalidEncryptedPayload)))
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			w.Header().Set("Content-Length", strconv.Itoa(len(invalidEncryptedPayload)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(invalidEncryptedPayload)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusBadGateway, rec.Code)
	assert.Contains(t, rec.Body.String(), "failed to decrypt object data")
}

// TestOpenObjectReadSeeker verifies seekable plaintext reads over encrypted upstream data.
func TestOpenObjectReadSeeker(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("abcdefghijklmnopqrstuvwxyz0123456789")
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	obj, err := proxy.OpenObject(context.Background(), "test-oid", dek)
	require.NoError(t, err)
	defer obj.Close()

	readBuf := make([]byte, 7)
	n, err := io.ReadFull(obj, readBuf)
	require.NoError(t, err)
	require.Equal(t, 7, n)
	assert.Equal(t, plaintext[:7], readBuf)

	pos, err := obj.Seek(5, io.SeekStart)
	require.NoError(t, err)
	assert.Equal(t, int64(5), pos)

	readBuf = make([]byte, 10)
	n, err = io.ReadFull(obj, readBuf)
	require.NoError(t, err)
	require.Equal(t, 10, n)
	assert.Equal(t, plaintext[5:15], readBuf)

	pos, err = obj.Seek(-4, io.SeekEnd)
	require.NoError(t, err)
	assert.Equal(t, int64(len(plaintext)-4), pos)

	tail, err := io.ReadAll(obj)
	require.NoError(t, err)
	assert.Equal(t, plaintext[len(plaintext)-4:], tail)
}

// TestOpenObjectRejectsReorderedChunks ensures position-bound AAD/nonces reject swapped frames.
func TestOpenObjectRejectsReorderedChunks(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := append(bytes.Repeat([]byte{0x41}, gitcrypt.ChunkSize), []byte("tail")...)
	encrypted := encryptChunkedForTest(t, plaintext, dek)
	frame0 := gitcrypt.ChunkSize + gitcrypt.ChunkOverheadBytes
	swapped := append(append([]byte{}, encrypted[frame0:]...), encrypted[:frame0]...)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, swapped)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	_, err = proxy.OpenObject(context.Background(), "test-oid", dek)
	require.Error(t, err)
	assert.ErrorIs(t, err, errObjectDecrypt)
}

// TestOpenObjectRejectsTruncatedObject ensures dropping the last chunk fails authentication
// because the remaining final frame was sealed with isLast=0.
func TestOpenObjectRejectsTruncatedObject(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := append(bytes.Repeat([]byte{0x41}, gitcrypt.ChunkSize), []byte("tail")...)
	encrypted := encryptChunkedForTest(t, plaintext, dek)
	frame0 := gitcrypt.ChunkSize + gitcrypt.ChunkOverheadBytes
	truncated := encrypted[:frame0]

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, truncated)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	_, err = proxy.OpenObject(context.Background(), "test-oid", dek)
	require.Error(t, err)
	assert.ErrorIs(t, err, errObjectDecrypt)
}

// TestOpenObjectMultiChunkRange keeps random-access range reads working across chunk boundaries.
func TestOpenObjectMultiChunkRange(t *testing.T) {
	dek := []byte("0123456789abcdef0123456789abcdef")
	plaintext := append(bytes.Repeat([]byte{0x42}, gitcrypt.ChunkSize), []byte("cross-boundary")...)
	encrypted := encryptChunkedForTest(t, plaintext, dek)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRangePayload(t, w, r, encrypted)
	}))
	defer upstream.Close()

	proxy, err := NewServer(ServerConfig{UpstreamURL: upstream.URL})
	require.NoError(t, err)

	start := gitcrypt.ChunkSize - 4
	end := gitcrypt.ChunkSize + 4
	req := httptest.NewRequest(http.MethodGet, "/objects/test-oid", nil)
	req.Header.Set(HeaderDEK, base64.StdEncoding.EncodeToString(dek))
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))

	rec := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(rec, req)

	require.Equal(t, http.StatusPartialContent, rec.Code)
	assert.Equal(t, plaintext[start:end+1], rec.Body.Bytes())
}

// encryptChunkedForTest builds fixture ciphertext with the production v2 framing.
func encryptChunkedForTest(t *testing.T, plaintext []byte, dek []byte) []byte {
	t.Helper()
	encrypted, err := gitcrypt.EncryptChunked(plaintext, dek)
	require.NoError(t, err)
	return encrypted
}

// serveRangePayload emulates upstream object server range behavior for proxy integration tests.
func serveRangePayload(t *testing.T, w http.ResponseWriter, r *http.Request, payload []byte) {
	t.Helper()
	switch r.Method {
	case http.MethodHead:
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.WriteHeader(http.StatusOK)
		return
	case http.MethodGet:
		rangeHeader := r.Header.Get("Range")
		if rangeHeader == "" {
			w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(payload)
			return
		}
		start, end, err := parseSimpleRange(rangeHeader, len(payload))
		if err != nil {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", len(payload)))
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		chunk := payload[start : end+1]
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(payload)))
		w.Header().Set("Content-Length", strconv.Itoa(len(chunk)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(chunk)
		return
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// parseSimpleRange parses single HTTP byte ranges to support local upstream test responses.
func parseSimpleRange(value string, total int) (int, int, error) {
	if !strings.HasPrefix(value, "bytes=") {
		return 0, 0, fmt.Errorf("invalid range")
	}
	parts := strings.Split(strings.TrimPrefix(value, "bytes="), "-")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("invalid range")
	}
	start, err := strconv.Atoi(parts[0])
	if err != nil || start < 0 {
		return 0, 0, fmt.Errorf("invalid range")
	}
	end := total - 1
	if parts[1] != "" {
		end, err = strconv.Atoi(parts[1])
		if err != nil {
			return 0, 0, fmt.Errorf("invalid range")
		}
	}
	if start >= total || end < start || end >= total {
		return 0, 0, fmt.Errorf("invalid range")
	}
	return start, end, nil
}
