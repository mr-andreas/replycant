package lfs

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var (
	// ErrInvalidOID rejects identifiers that could escape the content-addressed
	// layout or fail to match a SHA-256 digest.
	ErrInvalidOID = errors.New("invalid lfs oid")
	// ErrHashMismatch rejects uploads whose bytes do not hash to the declared OID.
	ErrHashMismatch = errors.New("lfs object hash mismatch")
	// ErrSizeMismatch rejects uploads whose length does not match the declared size.
	ErrSizeMismatch = errors.New("lfs object size mismatch")
	// ErrNotFound reports that an object is absent from the store.
	ErrNotFound = errors.New("lfs object not found")
	// ErrUploadInProgress rejects a second writer for an OID already being
	// uploaded so clients can fail fast instead of blocking on a long transfer.
	ErrUploadInProgress = errors.New("lfs object upload already in progress")
)

// Store is a file-backed Git LFS object store. Objects are content-addressed
// under a two-level prefix layout so large libraries avoid oversized directories,
// and writes commit via rename in the destination directory so crashes cannot
// leave a half-written object at the final path. Concurrent writers of the same
// OID are rejected immediately rather than serialized.
type Store struct {
	root string

	mu       sync.Mutex
	inFlight map[string]struct{}
}

// NewStore prepares a content store rooted at dir. The directory is created if
// missing so gitd can mount an empty volume on first boot.
func NewStore(dir string) (*Store, error) {
	if dir == "" {
		return nil, errors.New("lfs store root is required")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create lfs store root: %w", err)
	}
	return &Store{
		root:     dir,
		inFlight: make(map[string]struct{}),
	}, nil
}

// Root returns the configured store directory for callers that need to pass it
// through environment variables (for example the pre-receive hook).
func (s *Store) Root() string {
	return s.root
}

// ValidOID reports whether oid is a 64-character lowercase hex SHA-256 digest.
// Validation happens before any path is built so traversal is impossible.
func ValidOID(oid string) bool {
	if len(oid) != 64 {
		return false
	}
	for i := 0; i < len(oid); i++ {
		c := oid[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// ObjectPath returns the durable on-disk path for oid using the ab/cd/<rest>
// prefix layout. The oid must already be validated by the caller.
func (s *Store) ObjectPath(oid string) string {
	return filepath.Join(s.root, "objects", oid[:2], oid[2:4], oid)
}

// Exists reports whether a durable object file is present for oid.
func (s *Store) Exists(oid string) bool {
	if !ValidOID(oid) {
		return false
	}
	_, err := os.Stat(s.ObjectPath(oid))
	return err == nil
}

// Size returns the durable object size when present.
func (s *Store) Size(oid string) (int64, bool) {
	if !ValidOID(oid) {
		return 0, false
	}
	info, err := os.Stat(s.ObjectPath(oid))
	if err != nil {
		return 0, false
	}
	return info.Size(), true
}

// Open returns a read handle and file info for serving object bytes (including
// Range requests). Callers must close the file.
func (s *Store) Open(oid string) (*os.File, os.FileInfo, error) {
	if !ValidOID(oid) {
		return nil, nil, ErrInvalidOID
	}
	f, err := os.Open(s.ObjectPath(oid))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, ErrNotFound
		}
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	return f, info, nil
}

// Put streams an object into the store under oid. When the object already exists
// the reader is left unread so callers can answer early without wasting bandwidth.
// If another request is already writing the same OID, Put returns
// ErrUploadInProgress without reading the body so clients can move on.
func (s *Store) Put(ctx context.Context, oid string, size int64, r io.Reader) error {
	if !ValidOID(oid) {
		return ErrInvalidOID
	}
	if size < 0 {
		return ErrSizeMismatch
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	if s.Exists(oid) {
		return nil
	}
	if !s.tryAcquireOID(oid) {
		return ErrUploadInProgress
	}
	defer s.releaseOID(oid)

	// Another writer may have committed between the Exists check and acquire.
	if s.Exists(oid) {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	dir := filepath.Dir(s.ObjectPath(oid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create object directory: %w", err)
	}

	tmpName, err := randomTempName()
	if err != nil {
		return err
	}
	tmpPath := filepath.Join(dir, tmpName)
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("create temp object: %w", err)
	}

	committed := false
	defer func() {
		if !committed {
			_ = f.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	hasher := sha256.New()
	writer := io.MultiWriter(f, hasher)
	written, err := copyWithContext(ctx, writer, r)
	if err != nil {
		return err
	}
	if written != size {
		return fmt.Errorf("%w: got %d want %d", ErrSizeMismatch, written, size)
	}
	got := hex.EncodeToString(hasher.Sum(nil))
	if got != oid {
		return fmt.Errorf("%w: got %s want %s", ErrHashMismatch, got, oid)
	}

	if err := f.Sync(); err != nil {
		return fmt.Errorf("sync temp object: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close temp object: %w", err)
	}

	finalPath := s.ObjectPath(oid)
	if err := os.Rename(tmpPath, finalPath); err != nil {
		return fmt.Errorf("commit object: %w", err)
	}
	committed = true

	if err := syncDir(dir); err != nil {
		return fmt.Errorf("sync object directory: %w", err)
	}
	return nil
}

// tryAcquireOID marks oid as in-flight. Returns false when another writer
// already holds it so the caller can reject without waiting.
func (s *Store) tryAcquireOID(oid string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.inFlight[oid]; ok {
		return false
	}
	s.inFlight[oid] = struct{}{}
	return true
}

// releaseOID clears the in-flight mark so a later upload of the same OID can
// proceed after the current writer finishes or fails.
func (s *Store) releaseOID(oid string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.inFlight, oid)
}

// inFlightKeys is a test helper that exposes OIDs currently being written.
func (s *Store) inFlightKeys() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	keys := make([]string, 0, len(s.inFlight))
	for k := range s.inFlight {
		keys = append(keys, k)
	}
	return keys
}

// randomTempName builds a same-directory temp filename that will not collide with
// a durable OID path (those are 64 hex characters with no prefix).
func randomTempName() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate temp name: %w", err)
	}
	return ".tmp-" + hex.EncodeToString(b[:]), nil
}

// copyWithContext streams r into dst while honouring cancellation so a client
// disconnect does not leave a long-lived write holding an OID in-flight mark.
func copyWithContext(ctx context.Context, dst io.Writer, src io.Reader) (int64, error) {
	buf := make([]byte, 32*1024)
	var written int64
	for {
		if err := ctx.Err(); err != nil {
			return written, err
		}
		nr, readErr := src.Read(buf)
		if nr > 0 {
			nw, writeErr := dst.Write(buf[:nr])
			written += int64(nw)
			if writeErr != nil {
				return written, writeErr
			}
			if nw != nr {
				return written, io.ErrShortWrite
			}
		}
		if readErr == io.EOF {
			return written, nil
		}
		if readErr != nil {
			return written, readErr
		}
	}
}

// syncDir fsyncs the parent directory so a rename becomes durable across crashes.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
