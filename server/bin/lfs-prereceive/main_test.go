package main

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseDiffTreeBlobs_FiltersAndDedupes ensures diff-tree parsing keeps only unique non-zero new blob hashes.
func TestParseDiffTreeBlobs_FiltersAndDedupes(t *testing.T) {
	output := []byte(
		":100644 100644 1111111111111111111111111111111111111111 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa M\x00path/a\x00" +
			":100644 000000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0000000000000000000000000000000000000000 D\x00path/b\x00" +
			":100644 100644 cccccccccccccccccccccccccccccccccccccccc aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa M\x00path/c\x00",
	)

	blobs, err := parseDiffTreeBlobs(output)
	require.NoError(t, err)
	require.Len(t, blobs, 1)
	assert.Equal(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", blobs[0])
}

// TestCollectLFSObjects_DedupesByOID ensures multiple pointers to the same OID are validated once.
func TestCollectLFSObjects_DedupesByOID(t *testing.T) {
	originalRunner := gitRunner
	t.Cleanup(func() {
		gitRunner = originalRunner
	})

	pointer1 := "version https://git-lfs.github.com/spec/v1\n" +
		"oid sha256:1111111111111111111111111111111111111111111111111111111111111111\n" +
		"size 10\n"
	pointer2 := "version https://git-lfs.github.com/spec/v1\n" +
		"oid sha256:1111111111111111111111111111111111111111111111111111111111111111\n" +
		"size 10\n"

	gitRunner = func(args ...string) ([]byte, error) {
		switch {
		case len(args) == 6 && args[0] == "diff-tree" && args[5] == "commit-a":
			return []byte(
				":100644 100644 1111111111111111111111111111111111111111 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa M\x00binary/one\x00" +
					":100644 100644 3333333333333333333333333333333333333333 cccccccccccccccccccccccccccccccccccccccc M\x00notes.txt\x00",
			), nil
		case len(args) == 6 && args[0] == "diff-tree" && args[5] == "commit-b":
			return []byte(
				":100644 100644 2222222222222222222222222222222222222222 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb M\x00binary/two\x00",
			), nil
		case len(args) == 3 && args[0] == "cat-file" && args[1] == "-s" && args[2] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":
			return []byte("120\n"), nil
		case len(args) == 3 && args[0] == "cat-file" && args[1] == "-s" && args[2] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":
			return []byte("120\n"), nil
		case len(args) == 3 && args[0] == "cat-file" && args[1] == "-s" && args[2] == "cccccccccccccccccccccccccccccccccccccccc":
			return []byte("120\n"), nil
		case len(args) == 3 && args[0] == "cat-file" && args[2] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":
			return []byte(pointer1), nil
		case len(args) == 3 && args[0] == "cat-file" && args[2] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":
			return []byte(pointer2), nil
		case len(args) == 3 && args[0] == "cat-file" && args[2] == "cccccccccccccccccccccccccccccccccccccccc":
			return []byte("not an lfs pointer"), nil
		default:
			return nil, fmt.Errorf("unexpected args: %v", args)
		}
	}

	objects, err := collectLFSObjects([]string{"commit-a", "commit-b"})
	require.NoError(t, err)
	require.Len(t, objects, 1)
	assert.Equal(t, "1111111111111111111111111111111111111111111111111111111111111111", objects[0].OID)
	assert.EqualValues(t, 10, objects[0].Size)
}
