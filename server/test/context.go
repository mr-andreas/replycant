package test

import (
	"os"
	"os/exec"
	"testing"

	"github.com/mr-andreas/replycant/server/manifest"
	"github.com/mr-andreas/replycant/server/repo"
	"github.com/stretchr/testify/require"
)

type Context struct {
	Dir string

	Registry *manifest.Registry
}

func NewContext(t testing.TB) *Context {
	t.Helper()

	dir, err := os.MkdirTemp("/tmp/", "replycant-test-*")
	require.Nil(t, err)

	return &Context{
		Dir:      dir + "/repo",
		Registry: manifest.NewRegistry(),
	}
}

func (tc *Context) InitRepo(t *testing.T) *repo.Repo {
	r, err := repo.Init(tc.Registry, tc.Dir)
	require.Nil(t, err)
	return r
}

// Runs git clone on the repository in the test context and returns a new Repo.
// If path is empty, the repository will be cloned to a temporary directory.
func (tc *Context) CloneTo(t testing.TB, path string) *repo.Repo {
	if path == "" {
		dir, err := os.MkdirTemp("/tmp/", "replycant-test-cloned-*")
		require.Nil(t, err)
		path = dir
	}

	// Run git clone
	cmd := exec.Command("git", "clone", tc.Dir, path)
	err := cmd.Run()
	require.Nil(t, err)

	r, err := repo.Open(manifest.NewRegistry(), path)
	require.Nil(t, err)

	return r
}

// Closes the test context. If the test was successful, the temporary directory
// will be removed. If not, the directory will be left for inspection.
func (tc *Context) Close(t *testing.T) {
	if t.Failed() {
		t.Logf("Test failed, leaving temporary directory at %s", tc.Dir)
		return
	}

	err := os.RemoveAll(tc.Dir)
	require.Nil(t, err)
}
