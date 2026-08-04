package repo

import (
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/server/manifest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type testContext struct {
	Dir string
}

func newTestContext(t testing.TB) *testContext {
	t.Helper()

	dir, err := os.MkdirTemp("/tmp/", "replycant-test-*")
	require.Nil(t, err)

	return &testContext{
		Dir: dir + "/repo",
	}
}

// Runs git clone on the repository in the test context and returns a new Repo.
// If path is empty, the repository will be cloned to a temporary directory.
func (tc *testContext) cloneTo(t testing.TB, path string) *Repo {
	if path == "" {
		dir, err := os.MkdirTemp("/tmp/", "replycant-test-cloned-*")
		require.Nil(t, err)
		path = dir
	}

	// Run git clone
	cmd := exec.Command("git", "clone", tc.Dir, path)
	err := cmd.Run()
	require.Nil(t, err)

	r, err := Open(manifest.NewRegistry(), path)
	require.Nil(t, err)

	return r
}

func TestCommitAndLoad(t *testing.T) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	m := &testManifest{
		ID:      "foo",
		ANumber: 15,
	}
	ops := []Operation{
		{Type: OpTypeAdd, Manifest: m},
	}
	err = r.Commit(ops)
	require.Nil(t, err)

	manifests, err := r.LoadAllManifests()
	require.Nil(t, err)

	assert.Equal(t, 1, len(manifests))
	testManifests := manifests["github.com/mr-andreas/replycant/server/repo/testManifest"]
	assert.Equal(t, 1, len(testManifests))
	assert.Equal(t, *m, *testManifests[0].(*testManifest))
}

func TestCommitAndLoadFromOpen(t *testing.T) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	_, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	r, err := Open(mockRegistry, ctx.Dir)

	m := &testManifest{
		ID:      "foo",
		ANumber: 15,
	}
	ops := []Operation{
		{Type: OpTypeAdd, Manifest: m},
	}
	err = r.Commit(ops)
	require.Nil(t, err)

	manifests, err := r.LoadAllManifests()
	require.Nil(t, err)

	assert.Equal(t, 1, len(manifests))
	testManifests := manifests["github.com/mr-andreas/replycant/server/repo/testManifest"]
	assert.Equal(t, 1, len(testManifests))
	assert.Equal(t, *m, *testManifests[0].(*testManifest))
}

func TestCommitWithDirtyWorktree(t *testing.T) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	// Write a file to the worktree to make it dirty
	f, err := os.Create(ctx.Dir + "/dirty-file")
	require.Nil(t, err)
	f.Close()

	m := &testManifest{
		ID:      "foo",
		ANumber: 15,
	}
	ops := []Operation{
		{Type: OpTypeAdd, Manifest: m},
	}
	require.Nil(t, r.Commit(ops))

	// List all files in the worktree and make sure our "dirty-file" don't show
	// up. It should have been removed before our commit was done.
	entries, err := os.ReadDir(ctx.Dir)
	require.Nil(t, err)
	for _, entry := range entries {
		assert.NotEqual(t, "dirty-file", entry.Name())
	}
}

func TestSetBothManifestAndBinaryPathReturnsError(t *testing.T) {
	ops := []Operation{
		{Type: OpTypeAdd, Manifest: &testManifest{}, BinaryPath: "foo"},
	}

	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	err = r.Commit(ops)
	assert.ErrorIs(t, err, ErrManifestAndBinarySet)
}

func TestSetNoneOfManifestAndBinaryPathReturnsError(t *testing.T) {
	ops := []Operation{
		{Type: OpTypeAdd},
	}

	mockRegistry := manifest.NewRegistry()

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	err = r.Commit(ops)
	assert.ErrorIs(t, err, ErrManifestAndBinaryNotSet)
}

// Tests committing a binary file using BinaryPath and BinaryReader in
// Operation.
func TestCommitBinaryFile(t *testing.T) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	rd := func() (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader("this is a binary file")), nil
	}
	ops := []Operation{{
		Type:         OpTypeAdd,
		BinaryPath:   "testdata/testfile",
		BinaryReader: rd,
	}}
	require.Nil(t, r.Commit(ops))

	// Clone the repository and attempt to read the committed binary file
	cloned := ctx.cloneTo(t, "")
	wt, wtErr := cloned.repo.Worktree()
	require.Nil(t, wtErr)
	defer os.RemoveAll(wt.Filesystem.Root())

	// Read the binary file
	data, err := os.ReadFile(wt.Filesystem.Root() + "/binary/testdata/testfile")
	require.Nil(t, err)
	assert.Equal(t, "this is a binary file", string(data))
}

func TestOpenBinary(t *testing.T) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	ctx := newTestContext(t)
	r, err := Init(mockRegistry, ctx.Dir)
	require.Nil(t, err)

	rd := func() (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader("this is a binary file")), nil
	}
	ops := []Operation{{
		Type:         OpTypeAdd,
		BinaryPath:   "testdata/testfile",
		BinaryReader: rd,
	}}
	require.Nil(t, r.Commit(ops))

	// Read the binary file
	f, err := r.OpenBinary("testdata/testfile")
	require.Nil(t, err)
	data, dErr := io.ReadAll(f)
	require.Nil(t, dErr)
	assert.Equal(t, "this is a binary file", string(data))

	require.Nil(t, f.Close())
}
