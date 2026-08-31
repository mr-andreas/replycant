package gitcrypt

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestPinnedConstantsMatchAcrossLanguages keeps the gitdb version and
// encryption envelope string from drifting independently in Go, Swift,
// and TypeScript.
func TestPinnedConstantsMatchAcrossLanguages(t *testing.T) {
	t.Parallel()
	root := filepath.Join("..", "..")

	swiftVersion := mustExtractInt(t, filepath.Join(root, "iosapp", "GitDBPackage", "Sources", "GitDB", "DatabaseVersion.swift"),
		`static let current = (\d+)`)
	tsVersion := mustExtractInt(t, filepath.Join(root, "webapp", "src", "modules", "gitdb", "databaseVersion.ts"),
		`export const DATABASE_FORMAT_VERSION = (\d+)`)
	require.Equal(t, DatabaseFormatVersion, swiftVersion, "Swift DatabaseVersion.current")
	require.Equal(t, DatabaseFormatVersion, tsVersion, "TypeScript DATABASE_FORMAT_VERSION")

	swiftSource := mustRead(t, filepath.Join(root, "iosapp", "GitDBPackage", "Sources", "GitDB", "DatabaseVersion.swift"))
	tsSource := mustRead(t, filepath.Join(root, "webapp", "src", "modules", "gitdb", "databaseVersion.ts"))
	goSource := mustRead(t, filepath.Join(root, "pkg", "gitcrypt", "version.go"))
	require.Contains(t, swiftSource, "version == 0 || version == current")
	require.Contains(t, tsSource, "version === 0 || version === DATABASE_FORMAT_VERSION")
	require.Contains(t, goSource, "version == 0 || version == DatabaseFormatVersion")

	swiftEnvelope := mustExtractString(t, filepath.Join(root, "iosapp", "GitDBPackage", "Sources", "GitDB", "ManifestSyncEngine.swift"),
		`"(REPLYCANT-ENC-V1)\\n"`)
	tsEnvelope := mustExtractString(t, filepath.Join(root, "webapp", "src", "modules", "gitdb", "encryption.ts"),
		`const ENCRYPTED_MANIFEST_HEADER = "(REPLYCANT-ENC-V1)"`)
	require.Equal(t, ManifestHeader, swiftEnvelope, "Swift REPLYCANT-ENC-V1")
	require.Equal(t, ManifestHeader, tsEnvelope, "TypeScript ENCRYPTED_MANIFEST_HEADER")
}

func mustExtractInt(t *testing.T, path string, pattern string) int {
	t.Helper()
	value := mustExtractString(t, path, pattern)
	n, err := strconv.Atoi(value)
	require.NoError(t, err, path)
	return n
}

func mustExtractString(t *testing.T, path string, pattern string) string {
	t.Helper()
	raw := mustRead(t, path)
	match := regexp.MustCompile(pattern).FindSubmatch([]byte(raw))
	require.NotNil(t, match, "pattern %q not found in %s", pattern, path)
	return string(match[1])
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	require.NoError(t, err, path)
	return string(raw)
}
