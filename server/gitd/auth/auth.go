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
	cachedHead  plumbing.Hash
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

// Opens the bare repo once so auth can decide between bootstrap mode and
// a main-commit cache key without a second repository open.
func (a *Authenticator) repoState() (hasBranch bool, mainHash plumbing.Hash, err error) {
	repo, err := git.PlainOpen(a.repoPath)
	if err != nil {
		return false, plumbing.ZeroHash, fmt.Errorf("failed to open repository: %w", err)
	}

	refs, err := repo.References()
	if err != nil {
		return false, plumbing.ZeroHash, fmt.Errorf("failed to read references: %w", err)
	}

	errStop := errors.New("stop")
	err = refs.ForEach(func(ref *plumbing.Reference) error {
		if ref.Name().IsBranch() {
			hasBranch = true
			return errStop
		}
		return nil
	})
	if err != nil && err != errStop {
		return false, plumbing.ZeroHash, fmt.Errorf("error checking branches: %w", err)
	}

	if !hasBranch {
		return false, plumbing.ZeroHash, nil
	}

	ref, err := repo.Reference(plumbing.NewBranchReferenceName("main"), true)
	if err != nil {
		return true, plumbing.ZeroHash, fmt.Errorf("failed to find main branch: %w", err)
	}
	return true, ref.Hash(), nil
}

// Validates that the client certificate contains an authorized P-256 public key.
// Returns the username (filename without .pub extension) if authorized.
// For empty repositories, returns ErrUnauthorizedBootstrap to signal that bootstrap mode
// should be used (allows any valid P-256 certificate to push).
func (a *Authenticator) Authenticate(clientCert *x509.Certificate) (string, error) {
	if clientCert == nil {
		return "", fmt.Errorf("%w: no client certificate provided", ErrUnauthorized)
	}

	pubKey, err := extractP256PublicKey(clientCert)
	if err != nil {
		return "", fmt.Errorf("%w: invalid certificate: %s", ErrUnauthorized, err)
	}

	hasBranch, mainHash, err := a.repoState()
	if err != nil && !hasBranch {
		return "", fmt.Errorf("%w: failed to check repository state: %s", ErrUnauthorized, err)
	}
	if !hasBranch {
		return "bootstrap", ErrUnauthorizedBootstrap
	}
	if err != nil {
		return "", fmt.Errorf("%w: failed to load authorized keys: %s", ErrUnauthorized, err)
	}

	keys, err := a.loadAuthorizedKeys(mainHash)
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

// Reloads pubkeys when main has moved so a pushed revocation or enrollment
// takes effect on the next request instead of waiting out the TTL.
func (a *Authenticator) loadAuthorizedKeys(head plumbing.Hash) (map[string]*ecdsa.PublicKey, error) {
	a.mu.RLock()
	if head == a.cachedHead && time.Now().Before(a.cacheExpiry) {
		keys := a.cachedKeys
		a.mu.RUnlock()
		return keys, nil
	}
	a.mu.RUnlock()

	a.mu.Lock()
	defer a.mu.Unlock()

	if head == a.cachedHead && time.Now().Before(a.cacheExpiry) {
		return a.cachedKeys, nil
	}

	keys, err := a.readKeysFromCommit(head)
	if err != nil {
		return nil, err
	}

	a.cachedKeys = keys
	a.cachedHead = head
	a.cacheExpiry = time.Now().Add(a.cacheTTL)

	return keys, nil
}

// Reads all .pub files from the pubkeys/ tree of a specific main commit.
func (a *Authenticator) readKeysFromCommit(head plumbing.Hash) (map[string]*ecdsa.PublicKey, error) {
	repo, err := git.PlainOpen(a.repoPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open repository: %w", err)
	}

	commit, err := repo.CommitObject(head)
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
