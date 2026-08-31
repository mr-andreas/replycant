package gitcrypt

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseDatabaseVersionAcceptsExactInteger verifies the repo marker
// format so clients reject anything that is not a single decimal integer.
func TestParseDatabaseVersionAcceptsExactInteger(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{name: "one", input: "1", want: 1},
		{name: "one with newline", input: "1\n", want: 1},
		{name: "larger", input: "42", want: 42},
		{name: "larger with newline", input: "42\n", want: 42},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := ParseDatabaseVersion([]byte(tt.input))
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestParseDatabaseVersionRejectsMalformedContent keeps three language
// parsers aligned so a lenient client cannot accept a marker another
// client would refuse.
func TestParseDatabaseVersionRejectsMalformedContent(t *testing.T) {
	t.Parallel()
	cases := []string{
		"",
		"\n",
		"0",
		"01",
		"+1",
		"-1",
		"1 2",
		"1\n2",
		"1 ",
		" 1",
		"abc",
		"1\r\n",
		"\xef\xbb\xbf1",
		"1\n\n",
	}
	for _, input := range cases {
		t.Run(input, func(t *testing.T) {
			t.Parallel()
			_, err := ParseDatabaseVersion([]byte(input))
			require.Error(t, err)
		})
	}
}

// TestRequireSupportedDatabaseVersionAcceptsPinnedAndZero refuses any
// repo whose marker is not in the accepted set of {0, current}.
func TestRequireSupportedDatabaseVersionAcceptsPinnedAndZero(t *testing.T) {
	t.Parallel()
	require.NoError(t, RequireSupportedDatabaseVersion([]byte("1\n")))
	require.NoError(t, RequireSupportedDatabaseVersion([]byte("1")))
	require.NoError(t, RequireAcceptedDatabaseVersion(0))
	require.NoError(t, RequireAcceptedDatabaseVersion(1))

	err := RequireSupportedDatabaseVersion([]byte("2\n"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "2")
	assert.Contains(t, err.Error(), "1")

	err = RequireAcceptedDatabaseVersion(2)
	require.Error(t, err)

	err = RequireSupportedDatabaseVersion([]byte("01"))
	require.Error(t, err)
}

// TestRequireSupportedDatabaseVersionInWorktreeReadsMarker so Go
// consumers can gate on a checkout without each parsing the file.
func TestRequireSupportedDatabaseVersionInWorktreeReadsMarker(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "gitdb"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "gitdb", "version"), []byte("1\n"), 0o644))
	require.NoError(t, RequireSupportedDatabaseVersionInWorktree(dir))

	require.NoError(t, os.WriteFile(filepath.Join(dir, "gitdb", "version"), []byte("2\n"), 0o644))
	require.Error(t, RequireSupportedDatabaseVersionInWorktree(dir))

	missing := t.TempDir()
	require.NoError(t, RequireSupportedDatabaseVersionInWorktree(missing))
}
