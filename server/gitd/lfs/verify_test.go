package lfs

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParsePointer_Valid ensures valid Git LFS pointer blobs are recognized and parsed.
func TestParsePointer_Valid(t *testing.T) {
	content := "version https://git-lfs.github.com/spec/v1\n" +
		"oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" +
		"size 123\n"

	oid, size, ok := ParsePointer(content)
	require.True(t, ok)
	assert.Equal(t, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", oid)
	assert.EqualValues(t, 123, size)
}

// TestVerifyObjects_HeadChecksMissingAndDedupes ensures missing objects are rejected and duplicate OIDs are checked once.
func TestVerifyObjects_HeadChecksMissingAndDedupes(t *testing.T) {
	const (
		oidA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		oidB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	)

	var (
		mu       sync.Mutex
		requests = map[string]int{}
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodHead, r.Method)
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/objects/"), "/")
		require.Len(t, parts, 1)
		oid := parts[0]

		mu.Lock()
		requests[oid]++
		mu.Unlock()

		if oid == oidA {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	missing, err := VerifyObjects(server.URL, []Object{
		{OID: oidA, Size: 10},
		{OID: oidB, Size: 11},
		{OID: oidA, Size: 10},
	})
	require.NoError(t, err)
	assert.Equal(t, []string{oidA}, missing)

	mu.Lock()
	assert.Equal(t, 1, requests[oidA])
	assert.Equal(t, 1, requests[oidB])
	mu.Unlock()
}

// TestVerifyObjects_AllPresent ensures verification passes when all requested objects exist.
func TestVerifyObjects_AllPresent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodHead, r.Method)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	missing, err := VerifyObjects(server.URL, []Object{
		{OID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", Size: 10},
		{OID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", Size: 10},
	})
	require.NoError(t, err)
	assert.Empty(t, missing)
}

// TestVerifyObjects_InvalidLFSURL ensures malformed configuration is rejected.
func TestVerifyObjects_InvalidLFSURL(t *testing.T) {
	_, err := VerifyObjects("://bad-url", []Object{
		{OID: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", Size: 11},
	})
	require.Error(t, err)
}

// TestVerifyObjects_RespectsBasePath ensures object checks include configured LFS base path.
func TestVerifyObjects_RespectsBasePath(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/lfs/objects/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", r.URL.Path)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	baseURL := server.URL + "/lfs"
	missing, err := VerifyObjects(baseURL, []Object{
		{OID: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", Size: 10},
	})
	require.NoError(t, err)
	assert.Empty(t, missing)
}

// TestVerifyObjects_BatchingFailsEarly ensures later batches are skipped once a missing object is found.
func TestVerifyObjects_BatchingFailsEarly(t *testing.T) {
	const totalObjects = verifyBatchSize + 20

	var (
		mu            sync.Mutex
		requests      = map[string]int{}
		laterBatchOIDs = map[string]struct{}{}
		objects       = make([]Object, 0, totalObjects)
	)

	for i := 0; i < totalObjects; i++ {
		oid := fmt.Sprintf("%064x", i+1)
		objects = append(objects, Object{OID: oid, Size: int64(i + 1)})
		if i >= verifyBatchSize {
			laterBatchOIDs[oid] = struct{}{}
		}
	}
	missingOID := objects[7].OID

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodHead, r.Method)
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/objects/"), "/")
		require.Len(t, parts, 1)
		oid := parts[0]

		mu.Lock()
		requests[oid]++
		mu.Unlock()

		if oid == missingOID {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	missing, err := VerifyObjects(server.URL, objects)
	require.NoError(t, err)
	assert.Equal(t, []string{missingOID}, missing)

	mu.Lock()
	for oid := range laterBatchOIDs {
		assert.Zero(t, requests[oid], "expected no request for oid in later batch")
	}
	mu.Unlock()
}

// TestVerifyObjects_BatchingChecksAllWhenPresent ensures all batches run when no objects are missing.
func TestVerifyObjects_BatchingChecksAllWhenPresent(t *testing.T) {
	const totalObjects = (verifyBatchSize * 2) + 5

	var (
		mu       sync.Mutex
		requests = map[string]int{}
		objects  = make([]Object, 0, totalObjects)
	)

	for i := 0; i < totalObjects; i++ {
		oid := fmt.Sprintf("%064x", i+1000)
		objects = append(objects, Object{OID: oid, Size: int64(i + 1)})
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodHead, r.Method)
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/objects/"), "/")
		require.Len(t, parts, 1)
		oid := parts[0]

		mu.Lock()
		requests[oid]++
		mu.Unlock()

		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	missing, err := VerifyObjects(server.URL, objects)
	require.NoError(t, err)
	assert.Empty(t, missing)

	mu.Lock()
	assert.Len(t, requests, totalObjects)
	for _, obj := range objects {
		assert.Equal(t, 1, requests[obj.OID], "expected exactly one request per object")
	}
	mu.Unlock()
}
