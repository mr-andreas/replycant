package decryptproxy

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

const (
	// HeaderDEK carries the request-scoped DEK needed to decrypt an object.
	HeaderDEK = "X-Replycant-DEK"
	// lfsContentMediaType selects the LFS object content route on upstream storage.
	lfsContentMediaType = "application/vnd.git-lfs"
	// lfsMetaMediaType selects the LFS metadata route, which answers object size
	// from the metadata database without opening the stored object.
	lfsMetaMediaType = "application/vnd.git-lfs+json"
	// maxMetadataResponseBytes caps how much of a metadata reply is read before
	// giving up, so a non-LFS upstream answering with object content cannot pull
	// an entire media file into memory.
	maxMetadataResponseBytes = 64 << 10
	// maxCachedObjectSizes bounds size-cache growth for large libraries.
	maxCachedObjectSizes = 4096
)

var (
	// errObjectMetadata marks failures to read upstream encrypted object metadata.
	errObjectMetadata = errors.New("object metadata failure")
	// errObjectLayout marks failures to map encrypted object size to chunk layout.
	errObjectLayout = errors.New("object layout failure")
	// errObjectData marks failures to open or stream encrypted object bytes.
	errObjectData = errors.New("object data failure")
	// errObjectDecrypt marks failures to authenticate and decrypt encrypted chunks.
	errObjectDecrypt = errors.New("object decrypt failure")
)

// ServerConfig configures how the decrypting proxy reaches upstream object storage.
type ServerConfig struct {
	ListenAddr  string
	UpstreamURL string
}

// Server exposes strict DEK-based object decryption with plaintext byte-range support.
type Server struct {
	upstreamBaseURL string
	upstreamUser    string
	upstreamPass    string

	sizes *objectSizeCache
}

// objectSizeCache remembers encrypted object sizes across requests.
//
// A browser issues many range requests for a single video, and resolving the
// size upstream on every one of them adds a round trip before any byte can be
// served. LFS object IDs are content hashes, so a size can never change for a
// given ID and the cache needs no invalidation.
type objectSizeCache struct {
	mu       sync.Mutex
	sizes    map[string]int64
	inserted []string
	maxSize  int
}

// newObjectSizeCache builds a bounded FIFO size cache.
func newObjectSizeCache(maxSize int) *objectSizeCache {
	return &objectSizeCache{sizes: make(map[string]int64), maxSize: maxSize}
}

func (c *objectSizeCache) get(oid string) (int64, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	size, ok := c.sizes[oid]
	return size, ok
}

func (c *objectSizeCache) put(oid string, size int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.sizes[oid]; exists {
		return
	}
	if len(c.inserted) >= c.maxSize {
		oldest := c.inserted[0]
		c.inserted = c.inserted[1:]
		delete(c.sizes, oldest)
	}
	c.sizes[oid] = size
	c.inserted = append(c.inserted, oid)
}

// NewServer builds a decrypting proxy that targets the configured upstream object server.
func NewServer(cfg ServerConfig) (*Server, error) {
	parsed, err := url.Parse(cfg.UpstreamURL)
	if err != nil {
		return nil, fmt.Errorf("invalid upstream url: %w", err)
	}

	baseParsed := *parsed
	baseParsed.User = nil
	base := strings.TrimSuffix(baseParsed.String(), "/")
	username := ""
	password := ""
	if parsed.User != nil {
		username = parsed.User.Username()
		password, _ = parsed.User.Password()
	}

	return &Server{
		upstreamBaseURL: base,
		upstreamUser:    username,
		upstreamPass:    password,
		sizes:           newObjectSizeCache(maxCachedObjectSizes),
	}, nil
}

// Handler returns the HTTP handler that serves strict decrypting object requests.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/objects/", s.handleObjectGet)
	return mux
}

// handleObjectGet validates decryption headers and serves decrypted object bytes for media clients.
func (s *Server) handleObjectGet(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	oid, ok := parseObjectPath(r.URL.Path)
	if !ok {
		http.Error(w, "invalid object path", http.StatusBadRequest)
		return
	}

	dek, err := parseDEKHeader(r.Header.Get(HeaderDEK))
	if err != nil {
		http.Error(w, "invalid decryption headers", http.StatusBadRequest)
		return
	}

	object, err := s.OpenObject(r.Context(), oid, dek)
	if err != nil {
		switch {
		case errors.Is(err, errObjectMetadata):
			log.Printf("decryptd: metadata lookup failed for oid=%s: %v", oid, err)
			http.Error(w, "failed to read upstream metadata", http.StatusBadGateway)
		case errors.Is(err, errObjectLayout):
			log.Printf("decryptd: invalid encrypted layout for oid=%s: %v", oid, err)
			http.Error(w, "invalid encrypted object layout", http.StatusBadGateway)
		case errors.Is(err, errObjectData):
			log.Printf("decryptd: encrypted data stream failed for oid=%s: %v", oid, err)
			http.Error(w, "failed to read encrypted object data", http.StatusBadGateway)
		case errors.Is(err, errObjectDecrypt):
			log.Printf("decryptd: decrypt failed for oid=%s: %v", oid, err)
			http.Error(w, "failed to decrypt object data", http.StatusBadGateway)
		default:
			log.Printf("decryptd: open object failed for oid=%s: %v", oid, err)
			http.Error(w, "failed to open object", http.StatusBadGateway)
		}
		return
	}
	defer object.Close()

	// ServeContent would otherwise sniff the plaintext itself, and Go's sniffer
	// labels QuickTime recordings as application/octet-stream. Browsers refuse
	// to treat that as a playable source, so direct play needs a real type.
	if contentType, ok := object.detectContentType(); ok {
		w.Header().Set("Content-Type", contentType)
	}

	http.ServeContent(w, r, "", time.Time{}, object)
}

// isoBaseMediaBrandContentTypes maps ISO base media file format brands to the
// media types browsers accept for direct play. iPhone recordings arrive as
// QuickTime, which Go's own sniffer does not recognize.
var isoBaseMediaBrandContentTypes = map[string]string{
	"qt  ": "video/quicktime",
	"isom": "video/mp4",
	"iso2": "video/mp4",
	"mp41": "video/mp4",
	"mp42": "video/mp4",
	"avc1": "video/mp4",
	"M4V ": "video/x-m4v",
	"M4A ": "audio/mp4",
	"heic": "image/heic",
	"heix": "image/heic",
	"mif1": "image/heif",
}

// detectContentType resolves a media type from already-decrypted leading bytes,
// so type detection costs no extra upstream read.
func (o *DecryptedObject) detectContentType() (string, bool) {
	header, err := o.peekHeader()
	if err != nil || len(header) < 12 {
		return "", false
	}

	// ISO base media files start with a file-type box whose major brand is the
	// most reliable discriminator between QuickTime and the MP4 family.
	if string(header[4:8]) == "ftyp" {
		boxSize := int(binary.BigEndian.Uint32(header[0:4]))
		if contentType, ok := isoBaseMediaBrandContentTypes[string(header[8:12])]; ok {
			return contentType, true
		}
		if boxSize >= 16 && boxSize <= len(header) {
			// Fall back to compatible brands when the major brand is unknown.
			for offset := 16; offset+4 <= boxSize; offset += 4 {
				if contentType, ok := isoBaseMediaBrandContentTypes[string(header[offset:offset+4])]; ok {
					return contentType, true
				}
			}
		}
		return "video/mp4", true
	}

	detected := http.DetectContentType(header)
	if detected == "" || strings.HasPrefix(detected, "application/octet-stream") {
		return "", false
	}
	return detected, true
}

// peekHeader returns the object's leading bytes without disturbing read position.
func (o *DecryptedObject) peekHeader() ([]byte, error) {
	chunk, err := o.decryptedChunk(0)
	if err != nil {
		return nil, err
	}
	if len(chunk) > 512 {
		return chunk[:512], nil
	}
	return chunk, nil
}

// parseObjectPath extracts object IDs from /objects/{oid} routes.
func parseObjectPath(path string) (string, bool) {
	trimmed := strings.TrimPrefix(path, "/objects/")
	if trimmed == "" || strings.Contains(trimmed, "/") {
		return "", false
	}
	return trimmed, true
}

// parseDEKHeader validates and decodes a base64 32-byte DEK header.
func parseDEKHeader(value string) ([]byte, error) {
	if value == "" {
		return nil, errors.New("missing dek")
	}
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("invalid dek encoding: %w", err)
	}
	if len(decoded) != 32 {
		return nil, errors.New("invalid dek length")
	}
	return decoded, nil
}

// computeLayout derives plaintext sizing metadata from encrypted size using the
// repo-wide chunk constant so clients cannot supply attacker-controlled geometry.
func computeLayout(encryptedSize int64) (plainSize int, totalChunks int, lastChunkPlainSize int, err error) {
	if encryptedSize <= 0 {
		return 0, 0, 0, errors.New("encrypted object must not be empty")
	}
	encryptedChunkSize := int64(gitcrypt.ChunkSize + gitcrypt.ChunkOverheadBytes)
	totalChunks = int((encryptedSize + encryptedChunkSize - 1) / encryptedChunkSize)
	if totalChunks <= 0 {
		return 0, 0, 0, errors.New("invalid chunk count")
	}
	plainSize64 := encryptedSize - int64(totalChunks*gitcrypt.ChunkOverheadBytes)
	if plainSize64 <= 0 {
		return 0, 0, 0, errors.New("invalid plaintext size")
	}
	if plainSize64 > int64(^uint(0)>>1) {
		return 0, 0, 0, errors.New("plaintext too large")
	}
	plainSize = int(plainSize64)
	lastChunkPlainSize = plainSize - ((totalChunks - 1) * gitcrypt.ChunkSize)
	if lastChunkPlainSize <= 0 || lastChunkPlainSize > gitcrypt.ChunkSize {
		return 0, 0, 0, errors.New("invalid last chunk layout")
	}
	return plainSize, totalChunks, lastChunkPlainSize, nil
}

// fetchEncryptedObjectSize reads the encrypted upstream object size required for range math.
//
// The LFS metadata API is tried first because it is the only lookup that cannot
// touch stored object content. The HEAD and range-probe fallbacks exist for
// plain object stores that do not implement the LFS metadata route, but both are
// pathological against git-lfs-test-server: it omits Content-Length on HEAD
// while still streaming the whole file off disk, and it ignores range ends, so a
// bytes=0-0 probe streams the entire object. On a large video that turned every
// range request into a full-object disk read.
func (s *Server) fetchEncryptedObjectSize(ctx context.Context, oid string) (int64, error) {
	if size, ok := s.sizes.get(oid); ok {
		return size, nil
	}

	size, err := s.fetchEncryptedObjectSizeFromMetadata(ctx, oid)
	if err == nil {
		s.sizes.put(oid, size)
		return size, nil
	}
	metadataErr := err

	size, err = s.fetchEncryptedObjectSizeFromHead(ctx, oid)
	if err == nil {
		s.sizes.put(oid, size)
		return size, nil
	}
	headErr := err

	size, err = s.fetchEncryptedObjectSizeFromRangeProbe(ctx, oid)
	if err != nil {
		return 0, fmt.Errorf("metadata lookup failed (%w), head failed (%w), range probe failed: %w", metadataErr, headErr, err)
	}
	s.sizes.put(oid, size)
	return size, nil
}

// fetchEncryptedObjectSizeFromMetadata resolves object size through the LFS
// metadata route, which answers from the metadata database and never opens the
// stored object.
func (s *Server) fetchEncryptedObjectSizeFromMetadata(ctx context.Context, oid string) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.upstreamObjectURL(oid), nil)
	if err != nil {
		return 0, err
	}
	s.setUpstreamHeaders(req.Header)
	req.Header.Set("Accept", lfsMetaMediaType)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("upstream metadata status: %d", resp.StatusCode)
	}
	// Guards against stores that ignore Accept and answer with object content,
	// which would otherwise be streamed into the JSON decoder.
	if !strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "json") {
		return 0, errors.New("upstream metadata route returned non-json content")
	}

	var payload struct {
		Size int64 `json:"size"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxMetadataResponseBytes)).Decode(&payload); err != nil {
		return 0, fmt.Errorf("decode metadata: %w", err)
	}
	if payload.Size <= 0 {
		return 0, errors.New("upstream metadata reported no object size")
	}
	return payload.Size, nil
}

// fetchEncryptedObjectSizeFromHead supports plain object stores that report size
// on HEAD without implementing the LFS metadata route.
func (s *Server) fetchEncryptedObjectSizeFromHead(ctx context.Context, oid string) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, s.upstreamObjectURL(oid), nil)
	if err != nil {
		return 0, err
	}
	s.setUpstreamHeaders(req.Header)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("upstream metadata status: %d", resp.StatusCode)
	}
	size, ok := parsePositiveContentLength(resp.Header.Get("Content-Length"))
	if !ok {
		return 0, errors.New("upstream head omitted content length")
	}
	return size, nil
}

// fetchEncryptedObjectSizeFromRangeProbe recovers object size when HEAD metadata omits content length.
func (s *Server) fetchEncryptedObjectSizeFromRangeProbe(ctx context.Context, oid string) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.upstreamObjectURL(oid), nil)
	if err != nil {
		return 0, err
	}
	s.setUpstreamHeaders(req.Header)
	req.Header.Set("Range", "bytes=0-0")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusPartialContent:
		size, ok := parseContentRangeTotalSize(resp.Header.Get("Content-Range"))
		if !ok {
			return 0, errors.New("missing content range total")
		}
		return size, nil
	case http.StatusOK:
		size, ok := parsePositiveContentLength(resp.Header.Get("Content-Length"))
		if !ok {
			return 0, errors.New("missing content length")
		}
		return size, nil
	default:
		return 0, fmt.Errorf("upstream range probe status: %d", resp.StatusCode)
	}
}

// parsePositiveContentLength validates and parses positive content length metadata.
func parsePositiveContentLength(value string) (int64, bool) {
	if value == "" {
		return 0, false
	}
	size, err := strconv.ParseInt(value, 10, 64)
	if err != nil || size <= 0 {
		return 0, false
	}
	return size, true
}

// parseContentRangeTotalSize extracts the total object size from an HTTP Content-Range header.
func parseContentRangeTotalSize(value string) (int64, bool) {
	if !strings.HasPrefix(value, "bytes ") {
		return 0, false
	}
	slashIndex := strings.LastIndex(value, "/")
	if slashIndex == -1 || slashIndex == len(value)-1 {
		return 0, false
	}
	total := strings.TrimSpace(value[slashIndex+1:])
	if total == "*" {
		return 0, false
	}
	size, err := strconv.ParseInt(total, 10, 64)
	if err != nil || size <= 0 {
		return 0, false
	}
	return size, true
}

// OpenObject constructs a seekable plaintext object reader for encrypted upstream storage.
func (s *Server) OpenObject(ctx context.Context, oid string, dek []byte) (*DecryptedObject, error) {
	encryptedSize, err := s.fetchEncryptedObjectSize(ctx, oid)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errObjectMetadata, err)
	}
	plainSize, totalChunks, lastChunkPlainSize, err := computeLayout(encryptedSize)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errObjectLayout, err)
	}
	block, err := aes.NewCipher(dek)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errObjectDecrypt, err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errObjectDecrypt, err)
	}

	object := &DecryptedObject{
		server:             s,
		ctx:                ctx,
		oid:                oid,
		gcm:                gcm,
		chunkSize:          gitcrypt.ChunkSize,
		totalChunks:        totalChunks,
		lastChunkPlainSize: lastChunkPlainSize,
		encryptedSize:      encryptedSize,
		plainSize:          int64(plainSize),
	}

	if err := object.primeFirstChunk(); err != nil {
		_ = object.Close()
		if errors.Is(err, errChunkAuthentication) {
			return nil, fmt.Errorf("%w: %w", errObjectDecrypt, err)
		}
		return nil, fmt.Errorf("%w: %w", errObjectData, err)
	}
	return object, nil
}

// openEncryptedRange opens a normalized encrypted byte window stream from upstream storage.
func (s *Server) openEncryptedRange(ctx context.Context, oid string, start int64, end int64) (io.ReadCloser, error) {
	if end < start {
		return nil, errors.New("invalid encrypted range window")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.upstreamObjectURL(oid), nil)
	if err != nil {
		return nil, err
	}
	s.setUpstreamHeaders(req.Header)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
		defer resp.Body.Close()
		return nil, fmt.Errorf("upstream data status: %d", resp.StatusCode)
	}

	expectedLen := end - start + 1
	if resp.StatusCode == http.StatusOK {
		if _, err := io.CopyN(io.Discard, resp.Body, start); err != nil {
			resp.Body.Close()
			return nil, err
		}
	}

	return &limitedReadCloser{
		Reader: io.LimitReader(resp.Body, expectedLen),
		Closer: resp.Body,
	}, nil
}

// upstreamObjectURL builds the canonical upstream object URL for the requested OID.
func (s *Server) upstreamObjectURL(oid string) string {
	return fmt.Sprintf("%s/objects/%s", s.upstreamBaseURL, oid)
}

// setUpstreamHeaders applies authentication and required accept headers for upstream calls.
func (s *Server) setUpstreamHeaders(headers http.Header) {
	headers.Set("Accept", lfsContentMediaType)
	if s.upstreamUser != "" {
		headers.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(s.upstreamUser+":"+s.upstreamPass)))
	}
}

// limitedReadCloser keeps response body lifetime tied to limited stream reads.
type limitedReadCloser struct {
	io.Reader
	io.Closer
}
