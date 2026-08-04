package media

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"sort"
	"testing"

	"github.com/mr-andreas/replycant/server/test"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

func logYAML(t *testing.T, object any) {
	t.Helper()

	// Convert the object to YAML
	yaml, err := yaml.Marshal(object)
	require.Nil(t, err)

	// Log the YAML
	t.Log(string(yaml))
}

// Tests adding all files in the test directory to a repository
func TestRecursiveAdd(t *testing.T) {
	ctx := newTestContext(t)
	defer ctx.Close(t)

	r := ctx.InitRepo(t)
	err := RecursiveAdd("../test", r)
	require.Nil(t, err)

	// Check that manifests for all files were added
	manifests, err := r.LoadAllManifests()
	require.Nil(t, err)

	originals := manifests["github.com/mr-andreas/replycant/server/media/Original"]
	logYAML(t, originals)
	require.Len(t, originals, len(test.MediaTestFiles))

	// Sort the files by path name
	sort.Slice(originals, func(i, j int) bool {
		return originals[i].(*Original).Path < originals[j].(*Original).Path
	})

	for i, file := range test.MediaTestFiles {
		assert.Equal(t, file.AbsPath(), originals[i].(*Original).Path)
		assert.Equal(t, file.Filesize, originals[i].(*Original).Filesize)
		assert.Equal(t, file.SHA256, originals[i].(*Original).SHA256)
	}

	// Also make sure that the files were added to the repository
	cloned := ctx.CloneTo(t, "")
	for _, org := range originals {
		f, fErr := cloned.OpenBinary("media/" + shardName(org.ManifestID()))
		require.Nil(t, fErr)

		assert.Equal(t, org.(*Original).SHA256, getSHA256Sum(t, f))
	}
}

func getSHA256Sum(t *testing.T, r io.Reader) string {
	t.Helper()

	h := sha256.New()
	_, err := io.Copy(h, r)
	require.Nil(t, err)

	return hex.EncodeToString(h.Sum(nil))
}

// Makes sure that running RecursiveAdd twice on the same directory does not
// add the same files twice
func TestRecursiveAddTwice(t *testing.T) {
	t.Skip("TODO")
}
