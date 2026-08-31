package gitcrypt

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

const (
	// DatabaseFormatVersion is the only gitdb/version this binary will
	// operate on. A mismatch is a hard refusal, never a branch into
	// older decryption or path-layout code.
	DatabaseFormatVersion = 1
	// DatabaseVersionPath is the plaintext marker at the repo root that
	// pins the on-disk database format independently of manifest
	// apiVersion.
	DatabaseVersionPath = "gitdb/version"
)

// ParseDatabaseVersion validates gitdb/version content before any client
// treats the repository as a compatible database.
func ParseDatabaseVersion(raw []byte) (int, error) {
	if len(raw) == 0 {
		return 0, fmt.Errorf("%s is empty", DatabaseVersionPath)
	}
	if raw[len(raw)-1] == '\n' {
		raw = raw[:len(raw)-1]
	}
	if len(raw) == 0 {
		return 0, fmt.Errorf("%s is empty", DatabaseVersionPath)
	}
	for _, b := range raw {
		if b < '0' || b > '9' {
			return 0, fmt.Errorf("invalid %s value %q", DatabaseVersionPath, string(raw))
		}
	}
	if raw[0] == '0' {
		return 0, fmt.Errorf("invalid %s value %q", DatabaseVersionPath, string(raw))
	}
	version, err := strconv.Atoi(string(raw))
	if err != nil {
		return 0, fmt.Errorf("invalid %s value %q", DatabaseVersionPath, string(raw))
	}
	return version, nil
}

// RequireSupportedDatabaseVersion refuses any marker that is not an
// exact match for DatabaseFormatVersion so a tampered value can only
// deny service, never select a weaker code path.
func RequireSupportedDatabaseVersion(raw []byte) error {
	version, err := ParseDatabaseVersion(raw)
	if err != nil {
		return err
	}
	if version != DatabaseFormatVersion {
		return fmt.Errorf(
			"unsupported gitdb database version %d (this client requires %d)",
			version,
			DatabaseFormatVersion,
		)
	}
	return nil
}

// RequireSupportedDatabaseVersionInWorktree reads gitdb/version from a
// checkout so Go tools can refuse before they rewrite encryption state
// or import media.
func RequireSupportedDatabaseVersionInWorktree(repoPath string) error {
	raw, err := os.ReadFile(filepath.Join(repoPath, DatabaseVersionPath))
	if err != nil {
		return fmt.Errorf("read %s: %w", DatabaseVersionPath, err)
	}
	return RequireSupportedDatabaseVersion(raw)
}
