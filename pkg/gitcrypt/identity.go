package gitcrypt

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/btcsuite/btcd/btcutil/bech32"
	"golang.org/x/crypto/curve25519"
)

const (
	// defaultDeviceName keeps first-run onboarding deterministic when users omit explicit device names.
	defaultDeviceName = "git-replycant"
	// keyTTL matches existing replycant client certificate lifetime expectations.
	keyTTL = 7 * 24 * time.Hour
)

// Identity stores onboarding metadata and keys needed for QR authorization and KEK unwrap.
type Identity struct {
	AgePrivateKeyBase64 string `json:"agePrivateKeyBase64"`
	AgePublicKey        string `json:"agePublicKey"`
	DeviceName          string `json:"deviceName"`
	DeviceUUID          string `json:"deviceUUID"`
	PublicKeySSH        string `json:"publicKeySSH"`
}

// LocalIdentity keeps resolved file paths so clone and filter operations can reuse one local identity.
type LocalIdentity struct {
	Identity        Identity
	IdentityPath    string
	ClientKeyPath   string
	ClientCertPath  string
	ConfigDirectory string
}

// EnsureLocalIdentity keeps one stable per-repository identity so onboarding never shares credentials across repos.
func EnsureLocalIdentity(repoRoot string, deviceName string) (LocalIdentity, bool, error) {
	configDir, err := resolveRepoIdentityDir(repoRoot)
	if err != nil {
		return LocalIdentity{}, false, err
	}
	local := LocalIdentity{
		IdentityPath:    filepath.Join(configDir, "identity.json"),
		ClientKeyPath:   filepath.Join(configDir, "client-key.pem"),
		ClientCertPath:  filepath.Join(configDir, "client-cert.pem"),
		ConfigDirectory: configDir,
	}
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return LocalIdentity{}, false, fmt.Errorf("failed to create config directory: %w", err)
	}

	existing, err := loadIdentity(local.IdentityPath)
	if err == nil {
		if err := validateIdentity(existing); err != nil {
			return LocalIdentity{}, false, err
		}
		if err := ensureFileExists(local.ClientKeyPath); err != nil {
			return LocalIdentity{}, false, err
		}
		if err := ensureFileExists(local.ClientCertPath); err != nil {
			return LocalIdentity{}, false, err
		}
		local.Identity = existing
		return local, false, nil
	}
	if !os.IsNotExist(err) {
		return LocalIdentity{}, false, fmt.Errorf("failed to load identity: %w", err)
	}

	identity, keyPEM, certPEM, err := CreateIdentityWithMTLS(deviceName)
	if err != nil {
		return LocalIdentity{}, false, err
	}
	if err := saveIdentity(local.IdentityPath, identity); err != nil {
		return LocalIdentity{}, false, err
	}
	if err := os.WriteFile(local.ClientKeyPath, keyPEM, 0o600); err != nil {
		return LocalIdentity{}, false, fmt.Errorf("failed to write client key: %w", err)
	}
	if err := os.WriteFile(local.ClientCertPath, certPEM, 0o600); err != nil {
		return LocalIdentity{}, false, fmt.Errorf("failed to write client cert: %w", err)
	}
	local.Identity = identity
	return local, true, nil
}

// LoadLocalIdentity loads repository-local identity material so filters never depend on global state.
func LoadLocalIdentity(repoRoot string) (LocalIdentity, error) {
	configDir, err := resolveRepoIdentityDir(repoRoot)
	if err != nil {
		return LocalIdentity{}, err
	}
	local := LocalIdentity{
		IdentityPath:    filepath.Join(configDir, "identity.json"),
		ClientKeyPath:   filepath.Join(configDir, "client-key.pem"),
		ClientCertPath:  filepath.Join(configDir, "client-cert.pem"),
		ConfigDirectory: configDir,
	}
	identity, err := loadIdentity(local.IdentityPath)
	if err != nil {
		if os.IsNotExist(err) {
			return LocalIdentity{}, fmt.Errorf("identity not initialized for repository; missing %s", local.IdentityPath)
		}
		return LocalIdentity{}, fmt.Errorf("failed to load identity: %w", err)
	}
	if err := validateIdentity(identity); err != nil {
		return LocalIdentity{}, err
	}
	if err := ensureFileExists(local.ClientKeyPath); err != nil {
		return LocalIdentity{}, err
	}
	if err := ensureFileExists(local.ClientCertPath); err != nil {
		return LocalIdentity{}, err
	}
	local.Identity = identity
	return local, nil
}

// BuildPublicKeyQrPayload keeps cross-device onboarding tied to the discovered server CA trust root.
func BuildPublicKeyQrPayload(identity Identity, caHash string) (string, error) {
	payload := map[string]string{
		"pubkey":     identity.PublicKeySSH,
		"age_pubkey": identity.AgePublicKey,
		"name":       identity.DeviceName,
		"uuid":       identity.DeviceUUID,
		"ca_hash":    caHash,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("failed to encode QR payload: %w", err)
	}
	return string(raw), nil
}

// CreateIdentityWithMTLS creates onboarding keys once so QR authorization and mTLS share one identity.
func CreateIdentityWithMTLS(deviceName string) (Identity, []byte, []byte, error) {
	name := sanitizeDeviceName(deviceName)
	if name == "" {
		name = defaultDeviceName
	}
	identity := Identity{
		DeviceName: name,
		DeviceUUID: strings.ToLower(newUUID()),
	}

	agePriv := make([]byte, 32)
	if _, err := rand.Read(agePriv); err != nil {
		return Identity{}, nil, nil, fmt.Errorf("failed to generate age private key: %w", err)
	}
	agePub, err := curve25519.X25519(agePriv, curve25519.Basepoint)
	if err != nil {
		return Identity{}, nil, nil, fmt.Errorf("failed to derive age public key: %w", err)
	}
	encodedAgePub, err := EncodeAgePublicKey(agePub)
	if err != nil {
		return Identity{}, nil, nil, err
	}
	identity.AgePrivateKeyBase64 = base64.StdEncoding.EncodeToString(agePriv)
	identity.AgePublicKey = encodedAgePub

	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Identity{}, nil, nil, fmt.Errorf("failed to generate P-256 private key: %w", err)
	}
	privateKeyPEM, err := encodePrivateKeyPEM(privateKey)
	if err != nil {
		return Identity{}, nil, nil, err
	}
	certDER, err := CreateSelfSignedCert(identity.DeviceName, privateKey, keyTTL)
	if err != nil {
		return Identity{}, nil, nil, err
	}
	certPEM := encodeCertificatePEM(certDER)

	sshPublicKey, err := FormatSSHPublicKey(&privateKey.PublicKey, identity.DeviceName)
	if err != nil {
		return Identity{}, nil, nil, err
	}
	identity.PublicKeySSH = sshPublicKey
	return identity, privateKeyPEM, certPEM, nil
}

// CreateSelfSignedCert allows first-run clients to authenticate via mTLS without external certificate issuance.
func CreateSelfSignedCert(deviceName string, privateKey *ecdsa.PrivateKey, validFor time.Duration) ([]byte, error) {
	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to generate certificate serial number: %w", err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: strings.TrimSpace(deviceName),
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(validFor),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create self-signed certificate: %w", err)
	}
	return certDER, nil
}

// FormatSSHPublicKey emits the exact SSH key text consumed by gitd pubkeys authorization.
func FormatSSHPublicKey(publicKey *ecdsa.PublicKey, comment string) (string, error) {
	if publicKey.Curve != elliptic.P256() {
		return "", fmt.Errorf("unsupported curve: expected P-256")
	}
	keyType := "ecdsa-sha2-nistp256"
	curveName := "nistp256"
	point := elliptic.Marshal(elliptic.P256(), publicKey.X, publicKey.Y)
	if len(point) == 0 {
		return "", fmt.Errorf("failed to marshal public key point")
	}
	wire := make([]byte, 0, 4+len(keyType)+4+len(curveName)+4+len(point))
	wire = appendSSHString(wire, []byte(keyType))
	wire = appendSSHString(wire, []byte(curveName))
	wire = appendSSHString(wire, point)
	encoded := base64.StdEncoding.EncodeToString(wire)
	if strings.TrimSpace(comment) != "" {
		return fmt.Sprintf("%s %s %s", keyType, encoded, strings.TrimSpace(comment)), nil
	}
	return fmt.Sprintf("%s %s", keyType, encoded), nil
}

// EncodeAgePublicKey emits canonical bech32 age recipients used by iOS and webapp.
func EncodeAgePublicKey(raw []byte) (string, error) {
	data, err := bech32.ConvertBits(raw, 8, 5, true)
	if err != nil {
		return "", fmt.Errorf("failed to convert age public key bits: %w", err)
	}
	out, err := bech32.Encode("age", data)
	if err != nil {
		return "", fmt.Errorf("failed to encode age bech32 public key: %w", err)
	}
	return out, nil
}

// resolveRepoIdentityDir ensures all onboarding material is scoped to the current repository's git directory.
func resolveRepoIdentityDir(repoRoot string) (string, error) {
	gitDir, err := resolveGitDir(repoRoot)
	if err != nil {
		return "", err
	}
	return filepath.Join(gitDir, "replycant"), nil
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

// loadIdentity reads persisted onboarding identity state for reuse across commands.
func loadIdentity(path string) (Identity, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Identity{}, err
	}
	var identity Identity
	if err := json.Unmarshal(raw, &identity); err != nil {
		return Identity{}, fmt.Errorf("failed to parse identity JSON: %w", err)
	}
	return identity, nil
}

// saveIdentity writes identity metadata so future runs keep a stable authorization fingerprint.
func saveIdentity(path string, identity Identity) error {
	data, err := json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal identity JSON: %w", err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("failed to write identity file: %w", err)
	}
	return nil
}

// validateIdentity catches malformed persisted data before clone and filter operations rely on it.
func validateIdentity(identity Identity) error {
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

// encodePrivateKeyPEM preserves TLS interoperability with git's sslKey setting.
func encodePrivateKeyPEM(privateKey *ecdsa.PrivateKey) ([]byte, error) {
	privateKeyDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal EC private key: %w", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateKeyDER}), nil
}

// encodeCertificatePEM stores generated certificates in a format git and OpenSSL both understand.
func encodeCertificatePEM(certDER []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
}

// appendSSHString writes SSH wire-format string fields for ECDSA public key serialization.
func appendSSHString(dst, data []byte) []byte {
	length := make([]byte, 4)
	binary.BigEndian.PutUint32(length, uint32(len(data)))
	dst = append(dst, length...)
	dst = append(dst, data...)
	return dst
}

// sanitizeDeviceName keeps filenames and UI payloads predictable across platforms.
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
	buf := make([]byte, 16)
	_, _ = rand.Read(buf)
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		uint32(buf[0])<<24|uint32(buf[1])<<16|uint32(buf[2])<<8|uint32(buf[3]),
		uint16(buf[4])<<8|uint16(buf[5]),
		uint16(buf[6])<<8|uint16(buf[7]),
		uint16(buf[8])<<8|uint16(buf[9]),
		uint64(buf[10])<<40|uint64(buf[11])<<32|uint64(buf[12])<<24|uint64(buf[13])<<16|uint64(buf[14])<<8|uint64(buf[15]),
	)
}

// ensureFileExists catches partial local setup early so clone failures remain explicit.
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
