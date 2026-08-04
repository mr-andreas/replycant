package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

var (
	ErrForbidden             = errors.New("forbidden")
	ErrUnauthorized          = errors.New("unauthorized")
	ErrUnauthorizedBootstrap = errors.New("unauthorized: bootstrap mode - repository is empty")
)

// Validates client certificates against P-256 ECDSA public keys stored in the repository.
// This enables git clients to authenticate using self-signed certificates based on
// P-256 keys that can also be used for PGP commit signing.
type Authenticator struct {
	repoPath string
	cacheTTL time.Duration

	mu          sync.RWMutex
	cachedKeys  map[string]*ecdsa.PublicKey // filename -> public key
	cacheExpiry time.Time
}

// Creates an authenticator that loads authorized keys from pubkeys/ on the main branch.
// Keys are cached to avoid reading the repository on every request.
func NewAuthenticator(repoPath string, cacheTTL time.Duration) *Authenticator {
	return &Authenticator{
		repoPath:   repoPath,
		cacheTTL:   cacheTTL,
		cachedKeys: make(map[string]*ecdsa.PublicKey),
	}
}

// Detects whether the repository is completely empty (no branches at all).
// Used to enable bootstrap mode where any valid P-256 certificate can push the initial commit.
func (a *Authenticator) isRepositoryEmpty() (bool, error) {
	repo, err := git.PlainOpen(a.repoPath)
	if err != nil {
		return false, fmt.Errorf("failed to open repository: %w", err)
	}

	// Get all references
	refs, err := repo.References()
	if err != nil {
		return false, fmt.Errorf("failed to read references: %w", err)
	}

	// Check if there are any branch references
	hasBranch := false
	errStop := errors.New("stop")
	err = refs.ForEach(func(ref *plumbing.Reference) error {
		if ref.Name().IsBranch() {
			hasBranch = true
			return errStop // Early exit
		}
		return nil
	})
	// Ignore our "stop" error
	if err != nil && err != errStop {
		return false, fmt.Errorf("error checking branches: %w", err)
	}

	// Repository is empty only if there are no branches at all
	return !hasBranch, nil
}

// Validates that the client certificate contains an authorized P-256 public key.
// Returns the username (filename without .pub extension) if authorized.
// For empty repositories, returns ErrUnauthorizedBootstrap to signal that bootstrap mode
// should be used (allows any valid P-256 certificate to push).
// Retries once with a fresh cache if authentication fails to handle recently added keys.
func (a *Authenticator) Authenticate(clientCert *x509.Certificate) (string, error) {
	username, err := a.tryAuthenticate(clientCert)
	if err == nil {
		return username, nil
	}

	// If authentication failed due to unauthorized key, clear cache and retry once
	// This handles the case where a key was recently added but not yet in cache
	if errors.Is(err, ErrUnauthorized) && strings.Contains(err.Error(), "public key not authorized") {
		a.clearCache()
		return a.tryAuthenticate(clientCert)
	}

	return username, err
}

// Performs a single authentication attempt against the cached authorized keys.
// Used by Authenticate() to enable retry logic with cache clearing.
func (a *Authenticator) tryAuthenticate(clientCert *x509.Certificate) (string, error) {
	if clientCert == nil {
		return "", fmt.Errorf("%w: no client certificate provided", ErrUnauthorized)
	}

	pubKey, err := extractP256PublicKey(clientCert)
	if err != nil {
		return "", fmt.Errorf("%w: invalid certificate: %s", ErrUnauthorized, err)
	}

	// Check if repository is empty (bootstrap mode)
	empty, err := a.isRepositoryEmpty()
	if err != nil {
		return "", fmt.Errorf("%w: failed to check repository state: %s", ErrUnauthorized, err)
	}
	if empty {
		// Return special error to signal bootstrap mode to the server
		return "bootstrap", ErrUnauthorizedBootstrap
	}

	keys, err := a.loadAuthorizedKeys()
	if err != nil {
		return "", fmt.Errorf("%w: failed to load authorized keys: %s", ErrUnauthorized, err)
	}

	for username, authorizedKey := range keys {
		if pubKey.Equal(authorizedKey) {
			return username, nil
		}
	}

	return "", fmt.Errorf("%w: public key not authorized", ErrUnauthorized)
}

// Invalidates the key cache, forcing a fresh read from repository on next load.
// Used when authentication fails to handle recently added keys.
func (a *Authenticator) clearCache() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.cacheExpiry = time.Time{} // Set to zero time to invalidate
}

// Loads authorized keys from pubkeys/ directory on main branch.
// Results are cached to minimize repository reads.
func (a *Authenticator) loadAuthorizedKeys() (map[string]*ecdsa.PublicKey, error) {
	a.mu.RLock()
	if time.Now().Before(a.cacheExpiry) {
		keys := a.cachedKeys
		a.mu.RUnlock()
		return keys, nil
	}
	a.mu.RUnlock()

	a.mu.Lock()
	defer a.mu.Unlock()

	// Double-check after acquiring write lock
	if time.Now().Before(a.cacheExpiry) {
		return a.cachedKeys, nil
	}

	keys, err := a.readKeysFromRepo()
	if err != nil {
		return nil, err
	}

	a.cachedKeys = keys
	a.cacheExpiry = time.Now().Add(a.cacheTTL)

	return keys, nil
}

// Reads all .pub files from pubkeys/ directory on main branch.
func (a *Authenticator) readKeysFromRepo() (map[string]*ecdsa.PublicKey, error) {
	repo, err := git.PlainOpen(a.repoPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open repository: %w", err)
	}

	ref, err := repo.Reference(plumbing.NewBranchReferenceName("main"), true)
	if err != nil {
		return nil, fmt.Errorf("failed to find main branch: %w", err)
	}

	commit, err := repo.CommitObject(ref.Hash())
	if err != nil {
		return nil, fmt.Errorf("failed to get commit: %w", err)
	}

	tree, err := commit.Tree()
	if err != nil {
		return nil, fmt.Errorf("failed to get tree: %w", err)
	}

	pubkeysTree, err := tree.Tree("pubkeys")
	if err != nil {
		return nil, fmt.Errorf("pubkeys/ directory not found: %w", err)
	}

	keys := make(map[string]*ecdsa.PublicKey)

	err = pubkeysTree.Files().ForEach(func(f *object.File) error {
		if !strings.HasSuffix(f.Name, ".pub") {
			return nil
		}

		content, err := f.Contents()
		if err != nil {
			return fmt.Errorf("failed to read %s: %w", f.Name, err)
		}

		pubKey, err := parseSSHPublicKey(content)
		if err != nil {
			return fmt.Errorf("failed to parse %s: %w", f.Name, err)
		}

		username := strings.TrimSuffix(f.Name, ".pub")
		keys[username] = pubKey

		return nil
	})

	if err != nil {
		return nil, err
	}

	return keys, nil
}

// Extracts P-256 ECDSA public key from X.509 certificate.
// Git clients use self-signed certificates containing their P-256 keys.
func extractP256PublicKey(cert *x509.Certificate) (*ecdsa.PublicKey, error) {
	pubKey, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("certificate does not contain ECDSA public key")
	}

	if pubKey.Curve != elliptic.P256() {
		return nil, fmt.Errorf("certificate uses wrong curve (expected P-256)")
	}

	return pubKey, nil
}

// Parses SSH format P-256 public key (ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY...).
// This format is standard for SSH keys and can be generated with ssh-keygen.
func parseSSHPublicKey(content string) (*ecdsa.PublicKey, error) {
	content = strings.TrimSpace(content)
	parts := strings.Fields(content)

	if len(parts) < 2 {
		return nil, fmt.Errorf("invalid SSH public key format")
	}

	if parts[0] != "ecdsa-sha2-nistp256" {
		return nil, fmt.Errorf("not a P-256 key (type: %s)", parts[0])
	}

	decoded, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("failed to decode base64: %w", err)
	}

	// SSH wire format for ECDSA:
	// 4 bytes: length of key type string
	// N bytes: key type string ("ecdsa-sha2-nistp256")
	// 4 bytes: length of curve identifier
	// M bytes: curve identifier ("nistp256")
	// 4 bytes: length of public key point
	// K bytes: public key point (uncompressed: 0x04 || X || Y)

	offset := 0

	// Read key type
	if len(decoded) < 4 {
		return nil, fmt.Errorf("decoded key too short")
	}
	keyTypeLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4

	if len(decoded) < offset+int(keyTypeLen) {
		return nil, fmt.Errorf("decoded key too short for key type")
	}
	keyType := string(decoded[offset : offset+int(keyTypeLen)])
	offset += int(keyTypeLen)

	if keyType != "ecdsa-sha2-nistp256" {
		return nil, fmt.Errorf("unexpected key type: %s", keyType)
	}

	// Read curve identifier
	if len(decoded) < offset+4 {
		return nil, fmt.Errorf("decoded key too short for curve length")
	}
	curveLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4

	if len(decoded) < offset+int(curveLen) {
		return nil, fmt.Errorf("decoded key too short for curve")
	}
	curveID := string(decoded[offset : offset+int(curveLen)])
	offset += int(curveLen)

	if curveID != "nistp256" {
		return nil, fmt.Errorf("unexpected curve: %s", curveID)
	}

	// Read public key point
	if len(decoded) < offset+4 {
		return nil, fmt.Errorf("decoded key too short for point length")
	}
	pointLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4

	if len(decoded) < offset+int(pointLen) {
		return nil, fmt.Errorf("decoded key too short for point data")
	}
	pointData := decoded[offset : offset+int(pointLen)]

	// Parse uncompressed point (0x04 || X || Y)
	if len(pointData) != 65 || pointData[0] != 0x04 {
		return nil, fmt.Errorf("invalid uncompressed point format")
	}

	curve := elliptic.P256()
	x, y := elliptic.Unmarshal(curve, pointData)
	if x == nil {
		return nil, fmt.Errorf("failed to unmarshal point")
	}

	return &ecdsa.PublicKey{
		Curve: curve,
		X:     x,
		Y:     y,
	}, nil
}
