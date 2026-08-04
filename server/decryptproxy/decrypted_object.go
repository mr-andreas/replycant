package decryptproxy

import (
	"context"
	"crypto/cipher"
	"errors"
	"fmt"
	"io"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

var (
	// errEncryptedPayloadTruncated marks short encrypted chunk data from upstream.
	errEncryptedPayloadTruncated = errors.New("truncated encrypted payload")
	// errChunkAuthentication marks failed AES-GCM authentication for a chunk.
	errChunkAuthentication = errors.New("chunk authentication failed")
)

// DecryptedObject provides transparent plaintext reads over encrypted chunk storage.
type DecryptedObject struct {
	server             *Server
	ctx                context.Context
	oid                string
	gcm                cipher.AEAD
	chunkSize          int
	totalChunks        int
	lastChunkPlainSize int
	encryptedSize      int64
	plainSize          int64

	pos int64

	stream          io.ReadCloser
	streamNextChunk int

	cachedChunkIndex int
	cachedChunk      []byte
	hasCachedChunk   bool

	closed bool
}

// Read satisfies io.Reader so callers can stream plaintext without buffering full objects.
func (o *DecryptedObject) Read(p []byte) (int, error) {
	if o.closed {
		return 0, errors.New("object closed")
	}
	if len(p) == 0 {
		return 0, nil
	}
	if o.pos >= o.plainSize {
		return 0, io.EOF
	}

	read := 0
	for read < len(p) && o.pos < o.plainSize {
		chunkIndex := int(o.pos / int64(o.chunkSize))
		chunk, err := o.decryptedChunk(chunkIndex)
		if err != nil {
			if read > 0 {
				return read, err
			}
			return 0, err
		}

		chunkStart := int64(chunkIndex * o.chunkSize)
		offsetInChunk := int(o.pos - chunkStart)
		n := copy(p[read:], chunk[offsetInChunk:])
		read += n
		o.pos += int64(n)
	}

	return read, nil
}

// Seek satisfies io.Seeker so range-aware HTTP serving can map plaintext offsets.
func (o *DecryptedObject) Seek(offset int64, whence int) (int64, error) {
	if o.closed {
		return 0, errors.New("object closed")
	}

	next := int64(0)
	switch whence {
	case io.SeekStart:
		next = offset
	case io.SeekCurrent:
		next = o.pos + offset
	case io.SeekEnd:
		next = o.plainSize + offset
	default:
		return 0, errors.New("invalid seek whence")
	}
	if next < 0 {
		return 0, errors.New("negative seek offset")
	}
	o.pos = next
	return o.pos, nil
}

// Close releases upstream resources once callers are done reading.
func (o *DecryptedObject) Close() error {
	o.closed = true
	return o.closeStream()
}

// primeFirstChunk decrypts chunk zero so a wrong DEK fails before any response
// body is written.
//
// It deliberately fetches a single chunk frame instead of opening the streaming
// read used for playback. A client that seeks elsewhere abandons the validation
// read immediately, and an open-ended stream would leave the object store
// pushing an entire media file that nobody consumes.
func (o *DecryptedObject) primeFirstChunk() error {
	encryptedChunkSize := int64(o.chunkSize + gitcrypt.ChunkOverheadBytes)
	end := encryptedChunkSize - 1
	if end > o.encryptedSize-1 {
		end = o.encryptedSize - 1
	}

	stream, err := o.server.openEncryptedRange(o.ctx, o.oid, 0, end)
	if err != nil {
		return fmt.Errorf("open encrypted range: %w", err)
	}
	defer stream.Close()

	chunk, err := o.readChunkFrom(stream, 0)
	if err != nil {
		return err
	}
	o.cachedChunk = chunk
	o.cachedChunkIndex = 0
	o.hasCachedChunk = true
	return nil
}

// decryptedChunk returns one plaintext chunk so reads can reuse chunk-level decrypt work.
func (o *DecryptedObject) decryptedChunk(chunkIndex int) ([]byte, error) {
	if chunkIndex < 0 || chunkIndex >= o.totalChunks {
		return nil, io.EOF
	}
	if o.hasCachedChunk && o.cachedChunkIndex == chunkIndex {
		return o.cachedChunk, nil
	}
	chunk, err := o.loadChunk(chunkIndex)
	if err != nil {
		return nil, err
	}
	o.cachedChunk = chunk
	o.cachedChunkIndex = chunkIndex
	o.hasCachedChunk = true
	return chunk, nil
}

// loadChunk keeps reads stream-friendly by reusing an open upstream range when possible.
// Nonce and AAD are derived from chunk index so wire-supplied framing cannot relocate chunks.
func (o *DecryptedObject) loadChunk(chunkIndex int) ([]byte, error) {
	if o.stream == nil || o.streamNextChunk != chunkIndex {
		if err := o.closeStream(); err != nil {
			return nil, err
		}
		encryptedChunkSize := int64(o.chunkSize + gitcrypt.ChunkOverheadBytes)
		start := int64(chunkIndex) * encryptedChunkSize
		stream, err := o.server.openEncryptedRange(o.ctx, o.oid, start, o.encryptedSize-1)
		if err != nil {
			return nil, fmt.Errorf("open encrypted range: %w", err)
		}
		o.stream = stream
		o.streamNextChunk = chunkIndex
	}

	decrypted, err := o.readChunkFrom(o.stream, chunkIndex)
	if err != nil {
		return nil, err
	}

	o.streamNextChunk++
	if o.streamNextChunk >= o.totalChunks {
		_ = o.closeStream()
	}
	return decrypted, nil
}

// readChunkFrom consumes exactly one encrypted frame from a positioned stream and
// authenticates it against its index, so streaming reads and the up-front
// validation read cannot diverge in how they verify chunk placement.
func (o *DecryptedObject) readChunkFrom(stream io.Reader, chunkIndex int) ([]byte, error) {
	isLast := chunkIndex == o.totalChunks-1
	plainLen := o.chunkSize
	if isLast {
		plainLen = o.lastChunkPlainSize
	}

	encryptedChunk := make([]byte, plainLen+gitcrypt.ChunkOverheadBytes)
	if _, err := io.ReadFull(stream, encryptedChunk); err != nil {
		return nil, errEncryptedPayloadTruncated
	}

	decrypted, err := o.gcm.Open(
		nil,
		gitcrypt.ChunkNonce(uint64(chunkIndex)),
		encryptedChunk,
		gitcrypt.ChunkAAD(uint64(chunkIndex), isLast),
	)
	if err != nil {
		return nil, errChunkAuthentication
	}
	return decrypted, nil
}

// closeStream ensures each upstream response body is closed exactly once.
func (o *DecryptedObject) closeStream() error {
	if o.stream == nil {
		return nil
	}
	err := o.stream.Close()
	o.stream = nil
	return err
}
