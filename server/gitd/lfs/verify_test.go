package lfs

import (
	"bytes"
	"context"
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

// TestMissingObjects_DedupesAndReportsAbsent covers the pre-receive existence check
// against the file-backed store without HTTP.
func TestMissingObjects_DedupesAndReportsAbsent(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	presentContent := []byte("present")
	present := oidFor(presentContent)
	require.NoError(t, store.Put(context.Background(), present, int64(len(presentContent)), bytes.NewReader(presentContent)))

	absent := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	missing := MissingObjects(store, []Object{
		{OID: absent, Size: 10},
		{OID: present, Size: int64(len(presentContent))},
		{OID: absent, Size: 10},
	})
	assert.Equal(t, []string{absent}, missing)
}

// TestMissingObjects_AllPresent ensures verification passes when every OID exists.
func TestMissingObjects_AllPresent(t *testing.T) {
	store, err := NewStore(t.TempDir())
	require.NoError(t, err)

	aContent := []byte("a")
	bContent := []byte("b")
	a := oidFor(aContent)
	b := oidFor(bContent)
	require.NoError(t, store.Put(context.Background(), a, int64(len(aContent)), bytes.NewReader(aContent)))
	require.NoError(t, store.Put(context.Background(), b, int64(len(bContent)), bytes.NewReader(bContent)))

	missing := MissingObjects(store, []Object{
		{OID: a, Size: 1},
		{OID: b, Size: 1},
	})
	assert.Empty(t, missing)
}
