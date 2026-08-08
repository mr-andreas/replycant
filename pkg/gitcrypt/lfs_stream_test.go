package gitcrypt

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestEncryptedSizeMatchesEncryptChunkedLength keeps pointer size and Content-Length
// consistent with the bytes NewChunkedEncryptReader emits.
func TestEncryptedSizeMatchesEncryptChunkedLength(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x09}, 32)
	sizes := []int{0, 1, ChunkSize - 1, ChunkSize, ChunkSize + 1, ChunkSize * 2, ChunkSize*2 + 7}
	for _, size := range sizes {
		plaintext := bytes.Repeat([]byte{0xab}, size)
		encrypted, err := EncryptChunked(plaintext, dek)
		require.NoError(t, err)
		assert.EqualValues(t, len(encrypted), EncryptedSize(int64(size)), "size=%d", size)
	}
}

// TestNewChunkedEncryptReaderMatchesEncryptChunked proves the streaming path is
// byte-identical to the buffered path across chunk boundaries.
func TestNewChunkedEncryptReaderMatchesEncryptChunked(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x0a}, 32)
	sizes := []int{0, 1, ChunkSize - 1, ChunkSize, ChunkSize + 1, ChunkSize * 2, ChunkSize*2 + 7}
	for _, size := range sizes {
		plaintext := bytes.Repeat([]byte{byte(size % 251)}, size)
		want, err := EncryptChunked(plaintext, dek)
		require.NoError(t, err)

		reader, err := NewChunkedEncryptReader(bytes.NewReader(plaintext), int64(size), dek)
		require.NoError(t, err)
		got, err := io.ReadAll(reader)
		require.NoError(t, err)
		assert.Equal(t, want, got, "size=%d", size)
	}
}

// TestNewChunkedEncryptReaderIsRepeatable is the property the two-pass importer
// upload depends on: same DEK and plaintext always yield the same ciphertext.
func TestNewChunkedEncryptReaderIsRepeatable(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x0b}, 32)
	plaintext := bytes.Repeat([]byte("repeat-me"), 9000)

	reader1, err := NewChunkedEncryptReader(bytes.NewReader(plaintext), int64(len(plaintext)), dek)
	require.NoError(t, err)
	pass1, err := io.ReadAll(reader1)
	require.NoError(t, err)

	reader2, err := NewChunkedEncryptReader(bytes.NewReader(plaintext), int64(len(plaintext)), dek)
	require.NoError(t, err)
	pass2, err := io.ReadAll(reader2)
	require.NoError(t, err)

	assert.Equal(t, pass1, pass2)
	roundtrip, err := DecryptChunked(pass1, dek)
	require.NoError(t, err)
	assert.Equal(t, plaintext, roundtrip)
}

// TestNewChunkedEncryptReaderRejectsSizeMismatch fails closed when the source
// yields fewer or more bytes than the declared plaintext size.
func TestNewChunkedEncryptReaderRejectsSizeMismatch(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x0c}, 32)
	plaintext := []byte("short")

	reader, err := NewChunkedEncryptReader(bytes.NewReader(plaintext), 100, dek)
	require.NoError(t, err)
	_, err = io.ReadAll(reader)
	require.Error(t, err)
}

// TestBuildLFSPointerRoundTrips produces a canonical pointer that survives
// replycant header append/strip and ParseLFSPointer.
func TestBuildLFSPointerRoundTrips(t *testing.T) {
	t.Parallel()
	oid := fmt.Sprintf("%x", sha256.Sum256([]byte("pointer-fixture")))
	base := BuildLFSPointer(oid, 42)
	assert.True(t, IsLFSPointer(base))

	withHeaders, err := AppendReplycantHeaders(base, 3, "wrapped-dek-value")
	require.NoError(t, err)
	parsed, err := ParseLFSPointer(withHeaders)
	require.NoError(t, err)
	assert.Equal(t, oid, parsed.OID)
	assert.EqualValues(t, 42, parsed.Size)
	assert.Equal(t, 3, parsed.KekEpoch)
	assert.Equal(t, "wrapped-dek-value", parsed.WrappedDEK)

	stripped, strippedParsed, err := StripReplycantHeaders(withHeaders)
	require.NoError(t, err)
	assert.Equal(t, string(base), string(stripped))
	assert.Equal(t, oid, strippedParsed.OID)
}
