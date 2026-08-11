package lfs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// oidFor returns the lowercase hex SHA-256 of content, matching LFS object IDs.
func oidFor(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

// countingReader tracks how many bytes were read so short-circuit paths can prove
// they did not consume an upload body.
type countingReader struct {
	r     io.Reader
	n     int64
	reads int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	atomic.AddInt64(&c.n, int64(n))
	atomic.AddInt64(&c.reads, 1)
	return n, err
}

// TestStore_ObjectPathLayout ensures objects land under objects/ab/cd/<rest> so
// large libraries do not create oversized directories.
func TestStore_ObjectPathLayout(t *testing.T) {
	root := t.TempDir()
	store, err := NewStore(root)
	require.NoError(t, err)

	content := []byte("layout-test")
	oid := oidFor(content)
	require.Len(t, oid, 64)

	err = store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content))
	require.NoError(t, err)

	expected := filepath.Join(root, "objects", oid[:2], oid[2:4], oid)
	_, err = os.Stat(expected)
	require.NoError(t, err, "object should exist at prefix path")
	assert.Equal(t, expected, store.ObjectPath(oid))

	// Explicit example from the storage layout design.
	example := "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"
	assert.Equal(t,
		filepath.Join(root, "objects", "4d", "7a", example),
		store.ObjectPath(example),
	)
}

// TestStore_PutRoundTrip verifies streamed writes commit readable content.
func TestStore_PutRoundTrip(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	content := []byte("hello-lfs-store")
	oid := oidFor(content)
	err = store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content))
	require.NoError(t, err)

	assert.True(t, store.Exists(oid))
	size, ok := store.Size(oid)
	require.True(t, ok)
	assert.Equal(t, int64(len(content)), size)

	f, info, err := store.Open(oid)
	require.NoError(t, err)
	defer f.Close()
	got, err := io.ReadAll(f)
	require.NoError(t, err)
	assert.Equal(t, content, got)
	assert.Equal(t, int64(len(content)), info.Size())
}

// TestStore_FailedWritesLeaveNothingCommitted ensures hash/size/read failures
// never promote a temp file into the durable object location.
func TestStore_FailedWritesLeaveNothingCommitted(t *testing.T) {
	root := t.TempDir()
	store, err := NewStore(root)
	require.NoError(t, err)

	content := []byte("good-content")
	oid := oidFor(content)

	t.Run("hash mismatch", func(t *testing.T) {
		wrong := []byte("different-content")
		err := store.Put(context.Background(), oid, int64(len(wrong)), bytes.NewReader(wrong))
		require.Error(t, err)
		assert.False(t, store.Exists(oid))
		assertNoTempFiles(t, root)
	})

	t.Run("size mismatch", func(t *testing.T) {
		err := store.Put(context.Background(), oid, int64(len(content))+1, bytes.NewReader(content))
		require.Error(t, err)
		assert.False(t, store.Exists(oid))
		assertNoTempFiles(t, root)
	})

	t.Run("reader error", func(t *testing.T) {
		err := store.Put(context.Background(), oid, 4, io.MultiReader(
			bytes.NewReader([]byte("ab")),
			&errReader{err: errors.New("boom")},
		))
		require.Error(t, err)
		assert.False(t, store.Exists(oid))
		assertNoTempFiles(t, root)
	})

	t.Run("cancelled context", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		err := store.Put(ctx, oid, int64(len(content)), bytes.NewReader(content))
		require.Error(t, err)
		assert.False(t, store.Exists(oid))
		assertNoTempFiles(t, root)
	})
}

// TestStore_ExistingObjectShortCircuit proves Put does not consume the body when
// the object is already present, matching the bandwidth-saving upload path.
func TestStore_ExistingObjectShortCircuit(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	content := []byte("already-here")
	oid := oidFor(content)
	require.NoError(t, store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content)))

	body := &countingReader{r: bytes.NewReader([]byte("already-here"))}
	err = store.Put(context.Background(), oid, int64(len(content)), body)
	require.NoError(t, err)
	assert.Zero(t, atomic.LoadInt64(&body.n), "existing object must not consume body")
	assert.Zero(t, atomic.LoadInt64(&body.reads))
}

// TestStore_ConcurrentSameOIDRejectsInFlight proves a second writer for the same
// OID fails immediately with ErrUploadInProgress instead of blocking, and does
// not consume its body while the first write is still streaming.
func TestStore_ConcurrentSameOIDRejectsInFlight(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	content := bytes.Repeat([]byte("x"), 64*1024)
	oid := oidFor(content)

	started := make(chan struct{}, 1)
	release := make(chan struct{})
	firstErr := make(chan error, 1)
	go func() {
		firstErr <- store.Put(context.Background(), oid, int64(len(content)), &gateReader{
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
	secondDone := make(chan error, 1)
	go func() {
		secondDone <- store.Put(context.Background(), oid, int64(len(content)), body)
	}()

	select {
	case err := <-secondDone:
		require.ErrorIs(t, err, ErrUploadInProgress)
	case <-time.After(2 * time.Second):
		t.Fatal("second Put blocked instead of failing fast")
	}
	assert.Zero(t, atomic.LoadInt64(&body.n), "conflicted Put must not consume body")
	assert.Zero(t, atomic.LoadInt64(&body.reads))
	assert.Contains(t, store.inFlightKeys(), oid)

	close(release)
	require.NoError(t, <-firstErr)
	assert.True(t, store.Exists(oid))
	assert.Empty(t, store.inFlightKeys(), "in-flight set should drain after writers finish")

	f, _, err := store.Open(oid)
	require.NoError(t, err)
	defer f.Close()
	got, err := io.ReadAll(f)
	require.NoError(t, err)
	assert.Equal(t, content, got)

	// After the durable object exists, a later Put succeeds without reading.
	later := &countingReader{r: bytes.NewReader(content)}
	require.NoError(t, store.Put(context.Background(), oid, int64(len(content)), later))
	assert.Zero(t, atomic.LoadInt64(&later.n))
}

// TestStore_ConcurrentSameOIDRace accepts either success or ErrUploadInProgress
// for racing writers: exactly one commits, late arrivals that lose the race but
// arrive after commit see the durable object and return nil.
func TestStore_ConcurrentSameOIDRace(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	content := bytes.Repeat([]byte("x"), 64*1024)
	oid := oidFor(content)

	const writers = 8
	var wg sync.WaitGroup
	errs := make(chan error, writers)
	start := make(chan struct{})
	wg.Add(writers)
	for i := 0; i < writers; i++ {
		go func() {
			defer wg.Done()
			<-start
			errs <- store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content))
		}()
	}
	close(start)
	wg.Wait()
	close(errs)

	var ok, conflicted int
	for err := range errs {
		switch {
		case err == nil:
			ok++
		case errors.Is(err, ErrUploadInProgress):
			conflicted++
		default:
			require.NoError(t, err)
		}
	}
	assert.GreaterOrEqual(t, ok, 1, "at least one writer must succeed")
	assert.Equal(t, writers, ok+conflicted)

	assert.True(t, store.Exists(oid))
	f, _, err := store.Open(oid)
	require.NoError(t, err)
	defer f.Close()
	got, err := io.ReadAll(f)
	require.NoError(t, err)
	assert.Equal(t, content, got)
	assert.Empty(t, store.inFlightKeys())
}

// TestStore_FailedWriteReleasesInFlight ensures a hash mismatch frees the OID so
// a subsequent correct upload can proceed immediately.
func TestStore_FailedWriteReleasesInFlight(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	content := []byte("good-content")
	oid := oidFor(content)
	wrong := []byte("different-content")

	err = store.Put(context.Background(), oid, int64(len(wrong)), bytes.NewReader(wrong))
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrHashMismatch)
	assert.Empty(t, store.inFlightKeys())
	assert.False(t, store.Exists(oid))

	require.NoError(t, store.Put(context.Background(), oid, int64(len(content)), bytes.NewReader(content)))
	assert.True(t, store.Exists(oid))
	assert.Empty(t, store.inFlightKeys())
}

// TestStore_ConcurrentDifferentOIDs ensures distinct OIDs do not share a lock so
// unrelated uploads can proceed in parallel.
func TestStore_ConcurrentDifferentOIDs(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	const n = 4
	var (
		wg      sync.WaitGroup
		started = make(chan struct{}, n)
		release = make(chan struct{})
		errs    = make(chan error, n)
	)
	wg.Add(n)
	for i := 0; i < n; i++ {
		content := []byte(fmt.Sprintf("object-%d", i))
		oid := oidFor(content)
		go func(oid string, content []byte) {
			defer wg.Done()
			r := &gateReader{
				r:       bytes.NewReader(content),
				started: started,
				release: release,
			}
			errs <- store.Put(context.Background(), oid, int64(len(content)), r)
		}(oid, content)
	}

	deadline := time.After(2 * time.Second)
	for i := 0; i < n; i++ {
		select {
		case <-started:
		case <-deadline:
			t.Fatal("writers of distinct OIDs appear serialized")
		}
	}
	close(release)
	wg.Wait()
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	assert.Empty(t, store.inFlightKeys())
}

// TestStore_RejectsInvalidOID keeps path construction unreachable for traversal
// and malformed identifiers.
func TestStore_RejectsInvalidOID(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	invalid := []string{
		"",
		"abc",
		"ABCD" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab",
		"../" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd/x",
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcg",
	}
	for _, oid := range invalid {
		err := store.Put(context.Background(), oid, 1, bytes.NewReader([]byte("x")))
		require.Error(t, err, "oid %q", oid)
		_, _, err = store.Open(oid)
		require.Error(t, err, "oid %q", oid)
		assert.False(t, store.Exists(oid))
	}
}

// errReader fails on the first Read so Put can exercise cleanup paths.
type errReader struct {
	err error
}

func (e *errReader) Read([]byte) (int, error) {
	return 0, e.err
}

// gateReader signals when the first byte is requested and waits until release,
// so tests can observe in-flight writers without completing the upload.
type gateReader struct {
	r       io.Reader
	started chan<- struct{}
	release <-chan struct{}
	once    sync.Once
}

func (g *gateReader) Read(p []byte) (int, error) {
	g.once.Do(func() {
		g.started <- struct{}{}
		<-g.release
	})
	return g.r.Read(p)
}

func assertNoTempFiles(t *testing.T, root string) {
	t.Helper()
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && len(info.Name()) >= 5 && info.Name()[:5] == ".tmp-" {
			return fmt.Errorf("leftover temp file: %s", path)
		}
		return nil
	})
	require.NoError(t, err)
}
