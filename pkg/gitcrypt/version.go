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

// IsAcceptedDatabaseVersion reports whether version is the compiled pin
// or the pre-marker integer 0. The check is an explicit set, not
// `<= current`, so a future bump to 2 does not silently keep accepting 1.
func IsAcceptedDatabaseVersion(version int) bool {
	return version == 0 || version == DatabaseFormatVersion
}

// RequireAcceptedDatabaseVersion refuses any integer that is not in the
// accepted set so a tampered value can only deny service.
func RequireAcceptedDatabaseVersion(version int) error {
	if !IsAcceptedDatabaseVersion(version) {
		return fmt.Errorf(
			"unsupported gitdb database version %d (this client requires %d)",
			version,
			DatabaseFormatVersion,
		)
	}
	return nil
}

// RequireSupportedDatabaseVersion parses a present marker and refuses
// any value outside the accepted set. Absence is handled by the
// worktree and ref readers, not by this parser.
func RequireSupportedDatabaseVersion(raw []byte) error {
	version, err := ParseDatabaseVersion(raw)
	if err != nil {
		return err
	}
	return RequireAcceptedDatabaseVersion(version)
}

// RequireSupportedDatabaseVersionInWorktree reads gitdb/version from a
// checkout so Go tools can refuse before they rewrite encryption state
// or import media. A missing file is version 0, the in-code stand-in
// for old alpha repositories.
func RequireSupportedDatabaseVersionInWorktree(repoPath string) error {
	raw, err := os.ReadFile(filepath.Join(repoPath, DatabaseVersionPath))
	if err != nil {
		if os.IsNotExist(err) {
			return RequireAcceptedDatabaseVersion(0)
		}
		return fmt.Errorf("read %s: %w", DatabaseVersionPath, err)
	}
	return RequireSupportedDatabaseVersion(raw)
}
