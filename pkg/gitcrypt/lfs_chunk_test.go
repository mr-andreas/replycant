package gitcrypt

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Fixed material for the shared cross-platform golden vector so Go, TypeScript,
// and Swift cannot silently drift on nonce/AAD/framing.
var (
	goldenDEK = bytes.Repeat([]byte{0x11}, 32)
	// Spans two chunks at ChunkSize so both index and isLast bindings are exercised.
	goldenPlaintext = append(bytes.Repeat([]byte{0x42}, ChunkSize), []byte("tail-7!")...)
	// SHA-256 of EncryptChunked(goldenPlaintext, goldenDEK); shared with TS/Swift.
	goldenCiphertextSHA256 = "a8300613749c6d09bb332763ed5ea3c547aee4f86d85b374483fb9c2af38e053"
)

// TestChunkSizeIs64KiB pins the repo-wide constant chosen after seek/throughput
// measurement so clients and decryptd cannot disagree on geometry.
func TestChunkSizeIs64KiB(t *testing.T) {
	t.Parallel()
	assert.Equal(t, 65_536, ChunkSize)
	assert.Equal(t, 16, ChunkOverheadBytes)
}

// TestChunkNonceMatchesIOSDerivation keeps the 0||u64BE(index) layout shared
// with EncryptionUtils.nonceForChunk so every encryptor emits identical nonces.
func TestChunkNonceMatchesIOSDerivation(t *testing.T) {
	t.Parallel()
	nonce := ChunkNonce(0)
	require.Len(t, nonce, 12)
	assert.Equal(t, make([]byte, 12), nonce)

	nonce = ChunkNonce(1)
	var expected [12]byte
	binary.BigEndian.PutUint64(expected[4:], 1)
	assert.Equal(t, expected[:], nonce)
}

// TestChunkAADBindsIndexAndLastFlag verifies AAD layout so reorder/truncation
// changes fail authentication rather than decrypting under the wrong position.
func TestChunkAADBindsIndexAndLastFlag(t *testing.T) {
	t.Parallel()
	aad := ChunkAAD(2, true)
	require.Equal(t, len("replycant-lfs-chunk-v1")+8+1, len(aad))
	assert.Equal(t, []byte("replycant-lfs-chunk-v1"), aad[:len("replycant-lfs-chunk-v1")])
	assert.Equal(t, uint64(2), binary.BigEndian.Uint64(aad[len("replycant-lfs-chunk-v1"):len("replycant-lfs-chunk-v1")+8]))
	assert.Equal(t, byte(1), aad[len(aad)-1])

	aadNotLast := ChunkAAD(2, false)
	assert.Equal(t, byte(0), aadNotLast[len(aadNotLast)-1])
	assert.NotEqual(t, aad, aadNotLast)
}

// TestEncryptChunkedRoundtrip verifies v2 framing recovers plaintext and uses
// 16-byte per-chunk overhead (ciphertext||tag, no wire nonce).
func TestEncryptChunkedRoundtrip(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x03}, 32)
	plaintext := bytes.Repeat([]byte("payload-"), 9000)

	encrypted, err := EncryptChunked(plaintext, dek)
	require.NoError(t, err)
	require.NotEmpty(t, encrypted)

	n := (len(plaintext) + ChunkSize - 1) / ChunkSize
	assert.Equal(t, len(plaintext)+n*ChunkOverheadBytes, len(encrypted))

	roundtrip, err := DecryptChunked(encrypted, dek)
	require.NoError(t, err)
	assert.Equal(t, plaintext, roundtrip)
}

// TestEncryptChunkedEmptyProducesZeroChunks keeps empty objects free of a
// spurious authenticated frame that other clients would reject.
func TestEncryptChunkedEmptyProducesZeroChunks(t *testing.T) {
	t.Parallel()
	dek := bytes.Repeat([]byte{0x03}, 32)
	encrypted, err := EncryptChunked(nil, dek)
	require.NoError(t, err)
	assert.Empty(t, encrypted)

	roundtrip, err := DecryptChunked(encrypted, dek)
	require.NoError(t, err)
	assert.Empty(t, roundtrip)
}

// TestDecryptChunkedRejectsReorderedChunks ensures swapping frames fails because
// index-derived nonces and AAD bind each chunk to its position.
func TestDecryptChunkedRejectsReorderedChunks(t *testing.T) {
	t.Parallel()
	encrypted, err := EncryptChunked(goldenPlaintext, goldenDEK)
	require.NoError(t, err)

	frame0 := ChunkSize + ChunkOverheadBytes
	require.Greater(t, len(encrypted), frame0)
	swapped := append(append([]byte{}, encrypted[frame0:]...), encrypted[:frame0]...)

	_, err = DecryptChunked(swapped, goldenDEK)
	require.Error(t, err)
}

// TestDecryptChunkedRejectsDroppedLastChunk ensures trailing truncation fails
// because the new last frame was sealed with isLast=0.
func TestDecryptChunkedRejectsDroppedLastChunk(t *testing.T) {
	t.Parallel()
	encrypted, err := EncryptChunked(goldenPlaintext, goldenDEK)
	require.NoError(t, err)

	frame0 := ChunkSize + ChunkOverheadBytes
	truncated := encrypted[:frame0]
	_, err = DecryptChunked(truncated, goldenDEK)
	require.Error(t, err)
}

// TestUnwrapDEKRejectsWrongEpoch binds wrapped DEKs to kek-epoch so an
// attacker cannot swap a DEK across epochs without detection.
func TestUnwrapDEKRejectsWrongEpoch(t *testing.T) {
	t.Parallel()
	kek := bytes.Repeat([]byte{0x01}, 32)
	dek := bytes.Repeat([]byte{0x02}, 32)

	wrapped, err := WrapDEK(kek, dek, 3)
	require.NoError(t, err)

	got, err := UnwrapDEK(wrapped, kek, 3)
	require.NoError(t, err)
	assert.Equal(t, dek, got)

	_, err = UnwrapDEK(wrapped, kek, 4)
	require.Error(t, err)
}

// TestChunkFramingGoldenVector pins the ciphertext digest shared with TypeScript
// and Swift so implementations cannot drift on nonce, AAD, or overhead.
func TestChunkFramingGoldenVector(t *testing.T) {
	t.Parallel()
	encrypted, err := EncryptChunked(goldenPlaintext, goldenDEK)
	require.NoError(t, err)
	assert.Equal(t, ChunkSize+7+2*ChunkOverheadBytes, len(encrypted))
	sum := sha256.Sum256(encrypted)
	assert.Equal(t, goldenCiphertextSHA256, hex.EncodeToString(sum[:]))
}

// TestAppendReplycantHeadersOmitsChunkSize removes attacker-malleable geometry
// from pointers now that ChunkSize is a compile-time constant.
func TestAppendReplycantHeadersOmitsChunkSize(t *testing.T) {
	t.Parallel()
	base := []byte("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 10\n")
	restored, err := AppendReplycantHeaders(base, 2, "wrapped-dek")
	require.NoError(t, err)
	assert.Contains(t, string(restored), "x-replycant-kek-epoch 2")
	assert.Contains(t, string(restored), "x-replycant-wrapped-dek wrapped-dek")
	assert.NotContains(t, string(restored), "x-replycant-chunk-size")
}

// TestParseLFSPointerIgnoresLegacyChunkSizeField accepts alpha wipes of old
// pointers by ignoring a leftover chunk-size line rather than requiring it.
func TestParseLFSPointerIgnoresLegacyChunkSizeField(t *testing.T) {
	t.Parallel()
	raw := []byte("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 10\nx-replycant-kek-epoch 2\nx-replycant-wrapped-dek wrapped\nx-replycant-chunk-size 4096\n")
	parsed, err := ParseLFSPointer(raw)
	require.NoError(t, err)
	assert.Equal(t, 2, parsed.KekEpoch)
	assert.Equal(t, "wrapped", parsed.WrappedDEK)
}
