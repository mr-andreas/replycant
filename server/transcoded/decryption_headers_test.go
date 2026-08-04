package transcoded

import (
	"encoding/base64"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseDecryptionHeaders keeps encrypted playback strict while preserving plaintext compatibility.
func TestParseDecryptionHeaders(t *testing.T) {
	validDEK := base64.StdEncoding.EncodeToString(make([]byte, 32))

	// Verifies plain requests remain valid when no decryption metadata is provided.
	t.Run("no headers", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/hls/hash/720p/1.0/segment_0.ts", nil)
		headers, present, err := parseDecryptionHeaders(req)
		require.NoError(t, err)
		assert.False(t, present)
		assert.Equal(t, DecryptionHeaders{}, headers)
	})

	// Prevents malformed DEKs from being forwarded to decryptd.
	t.Run("invalid dek", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/hls/hash/720p/1.0/segment_0.ts", nil)
		req.Header.Set(HeaderDEK, "not-base64")
		_, _, err := parseDecryptionHeaders(req)
		require.Error(t, err)
	})

	// Confirms valid encrypted playback metadata is accepted and forwarded.
	t.Run("valid headers", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/hls/hash/720p/1.0/segment_0.ts", nil)
		req.Header.Set(HeaderDEK, validDEK)
		headers, present, err := parseDecryptionHeaders(req)
		require.NoError(t, err)
		assert.True(t, present)
		assert.Equal(t, validDEK, headers.DEK)
	})
}

// TestSetCORSHeadersIncludesDecryptdHeaders keeps browser clients able to send decryption metadata.
func TestSetCORSHeadersIncludesDecryptdHeaders(t *testing.T) {
	rec := httptest.NewRecorder()
	setCORSHeaders(rec)
	allowed := rec.Header().Get("Access-Control-Allow-Headers")
	assert.Contains(t, allowed, HeaderDEK)
	assert.NotContains(t, allowed, "X-Replycant-Chunk-Size")
}

// TestGetHeadersAddsDecryptdPassThrough keeps ffmpeg requests aligned with decryptd's contract.
func TestGetHeadersAddsDecryptdPassThrough(t *testing.T) {
	client := NewUpstreamClient("http://user:pass@example.com")
	headers := client.GetHeaders(&DecryptionHeaders{
		DEK: "encoded-dek",
	})

	assert.Contains(t, headers, "Accept: application/vnd.git-lfs\r\n")
	assert.Contains(t, headers, "Authorization: Basic dXNlcjpwYXNz\r\n")
	assert.Contains(t, headers, HeaderDEK+": encoded-dek\r\n")
	assert.NotContains(t, headers, "X-Replycant-Chunk-Size")
}

// TestSanitizeArgsForLogRedactsHeaders prevents DEK leakage through debug command logging.
func TestSanitizeArgsForLogRedactsHeaders(t *testing.T) {
	args := []string{"-headers", HeaderDEK + ": secret", "-i", "http://example"}
	sanitized := sanitizeArgsForLog(args)
	assert.NotContains(t, sanitized, "secret")
	assert.Contains(t, sanitized, "[REDACTED_HEADERS]")
}
