package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

const (
	// defaultDeviceName keeps first-run onboarding deterministic when users omit explicit device names.
	defaultDeviceName = "git-replycant"
)

// sanitizeDeviceName normalizes user-provided labels into stable portable IDs.
func sanitizeDeviceName(input string) string {
	trimmed := strings.TrimSpace(strings.ToLower(input))
	if trimmed == "" {
		return defaultDeviceName
	}
	var b strings.Builder
	prevDash := false
	for _, ch := range trimmed {
		valid := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == ' '
		if !valid {
			continue
		}
		if ch == ' ' || ch == '-' {
			if prevDash {
				continue
			}
			b.WriteByte('-')
			prevDash = true
			continue
		}
		b.WriteRune(ch)
		prevDash = false
	}
	out := strings.Trim(b.String(), "-_")
	if out == "" {
		return defaultDeviceName
	}
	return out
}

// newUUID creates UUIDv4-compatible identifiers for onboarding payload compatibility.
func newUUID() string {
	identity, _, _, err := gitcrypt.CreateIdentityWithMTLS("uuid-only")
	if err != nil {
		return ""
	}
	return identity.DeviceUUID
}

// validateIdentity checks persisted identity fields before runtime usage.
func validateIdentity(identity gitcrypt.Identity) error {
	if strings.TrimSpace(identity.AgePrivateKeyBase64) == "" {
		return fmt.Errorf("identity is missing agePrivateKeyBase64")
	}
	rawKey, err := base64.StdEncoding.DecodeString(identity.AgePrivateKeyBase64)
	if err != nil {
		return fmt.Errorf("identity has invalid agePrivateKeyBase64: %w", err)
	}
	if len(rawKey) != 32 {
		return fmt.Errorf("identity has invalid age private key length: %d", len(rawKey))
	}
	if strings.TrimSpace(identity.AgePublicKey) == "" {
		return fmt.Errorf("identity is missing agePublicKey")
	}
	if strings.TrimSpace(identity.PublicKeySSH) == "" {
		return fmt.Errorf("identity is missing publicKeySSH")
	}
	if strings.TrimSpace(identity.DeviceName) == "" {
		return fmt.Errorf("identity is missing deviceName")
	}
	if strings.TrimSpace(identity.DeviceUUID) == "" {
		return fmt.Errorf("identity is missing deviceUUID")
	}
	return nil
}

// ensureFileExists guards identity loading against missing files and directory paths.
func ensureFileExists(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("missing required file: %s", path)
		}
		return fmt.Errorf("failed to stat file %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("expected file but found directory: %s", path)
	}
	return nil
}

// resolveGitDir resolves the effective .git directory so worktrees and custom git-dir layouts stay supported.
func resolveGitDir(repoRoot string) (string, error) {
	trimmedRoot := strings.TrimSpace(repoRoot)
	if trimmedRoot == "" {
		return "", fmt.Errorf("repository root is required")
	}
	absRoot, err := filepath.Abs(trimmedRoot)
	if err != nil {
		return "", fmt.Errorf("failed to resolve repository root: %w", err)
	}
	cmd := exec.Command("git", "-C", absRoot, "rev-parse", "--git-dir")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to resolve git dir for %s: %w", absRoot, err)
	}
	gitDir := strings.TrimSpace(string(out))
	if gitDir == "" {
		return "", fmt.Errorf("failed to resolve git dir for %s", absRoot)
	}
	if filepath.IsAbs(gitDir) {
		return gitDir, nil
	}
	return filepath.Join(absRoot, gitDir), nil
}
