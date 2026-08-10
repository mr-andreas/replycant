package lfs

import (
	"encoding/hex"
	"strconv"
	"strings"
)

const pointerVersionLine = "version https://git-lfs.github.com/spec/v1"

// Object represents one LFS object identity used for server-side existence checks.
type Object struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

// ParsePointer extracts the OID and size from a Git LFS pointer file to distinguish
// it from regular blobs during pre-receive validation.
func ParsePointer(content string) (oid string, size int64, ok bool) {
	lines := strings.Split(content, "\n")

	var (
		hasVersion bool
		hasOID     bool
		hasSize    bool
	)

	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}

		switch {
		case line == pointerVersionLine:
			hasVersion = true
		case strings.HasPrefix(line, "oid sha256:"):
			candidate := strings.TrimPrefix(line, "oid sha256:")
			if len(candidate) != 64 {
				return "", 0, false
			}
			if _, err := hex.DecodeString(candidate); err != nil {
				return "", 0, false
			}
			oid = strings.ToLower(candidate)
			hasOID = true
		case strings.HasPrefix(line, "size "):
			candidate := strings.TrimSpace(strings.TrimPrefix(line, "size "))
			parsed, err := strconv.ParseInt(candidate, 10, 64)
			if err != nil || parsed < 0 {
				return "", 0, false
			}
			size = parsed
			hasSize = true
		}
	}

	if !hasVersion || !hasOID || !hasSize {
		return "", 0, false
	}

	return oid, size, true
}
