package gitcrypt

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/btcsuite/btcd/btcutil/bech32"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

const (
	// ManifestHeader marks files that use replycant manifest envelope encryption.
	ManifestHeader = "REPLYCANT-ENC-V1"
	// manifestDelimiter separates manifest metadata from encrypted payload bytes.
	manifestDelimiter = "\n---\n"
)

var (
	// wrapSalt keeps KEK envelope unwrap compatible with existing replycant clients.
	wrapSalt = []byte("replycant-age-wrap-salt")
	// wrapInfo keeps KEK envelope unwrap compatible with existing replycant clients.
	wrapInfo = []byte("replycant-age-wrap-info")
)

// ComputeCAHash keeps QR ca_hash values aligned with iOS/webapp certificate matching.
func ComputeCAHash(certificatePEM string) (string, error) {
	normalized := strings.ReplaceAll(certificatePEM, "-----BEGIN CERTIFICATE-----", "")
	normalized = strings.ReplaceAll(normalized, "-----END CERTIFICATE-----", "")
	normalized = strings.Join(strings.Fields(normalized), "")
	if normalized == "" {
		return "", fmt.Errorf("certificate PEM is empty")
	}
	der, err := base64.StdEncoding.DecodeString(normalized)
	if err != nil {
		return "", fmt.Errorf("certificate PEM is invalid: %w", err)
	}
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:]), nil
}

// EncryptedManifest carries parsed envelope metadata needed for manifest decryption.
type EncryptedManifest struct {
	KekEpoch   int
	Ciphertext []byte
}

// ParseCurrentEpoch validates repository encryption/current content before filter writes.
func ParseCurrentEpoch(raw []byte) (int, error) {
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return 0, fmt.Errorf("encryption/current is empty")
	}
	epoch, err := strconv.Atoi(value)
	if err != nil || epoch < 1 {
		return 0, fmt.Errorf("invalid encryption/current epoch value %q", value)
	}
	return epoch, nil
}

// IsEncryptedManifest avoids decrypt attempts for plaintext manifests and pointer files.
func IsEncryptedManifest(raw []byte) bool {
	return bytes.HasPrefix(raw, []byte(ManifestHeader+"\n"))
}

// ParseEncryptedManifestHeader extracts the epoch and ciphertext from an envelope blob.
func ParseEncryptedManifestHeader(raw []byte) (EncryptedManifest, error) {
	delimiter := []byte(manifestDelimiter)
	index := bytes.Index(raw, delimiter)
	if index == -1 {
		return EncryptedManifest{}, fmt.Errorf("missing manifest delimiter")
	}
	header := string(raw[:index])
	lines := strings.Split(header, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != ManifestHeader {
		return EncryptedManifest{}, fmt.Errorf("invalid manifest header")
	}
	epoch := 0
	for _, line := range lines[1:] {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "kek-epoch:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(trimmed, "kek-epoch:"))
		parsed, err := strconv.Atoi(value)
		if err != nil {
			return EncryptedManifest{}, fmt.Errorf("invalid kek-epoch value: %w", err)
		}
		epoch = parsed
		break
	}
	if epoch < 1 {
		return EncryptedManifest{}, fmt.Errorf("missing kek-epoch metadata")
	}
	return EncryptedManifest{KekEpoch: epoch, Ciphertext: raw[index+len(delimiter):]}, nil
}

// EncryptManifestEnvelope keeps clean-filter output aligned with webapp/server manifest format.
func EncryptManifestEnvelope(plaintext []byte, kek []byte, epoch int) ([]byte, error) {
	body, err := EncryptAesGcmCombined(kek, plaintext, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to encrypt manifest body: %w", err)
	}
	header := fmt.Sprintf("%s\nkek-epoch: %d%s", ManifestHeader, epoch, manifestDelimiter)
	out := make([]byte, 0, len(header)+len(body))
	out = append(out, []byte(header)...)
	out = append(out, body...)
	return out, nil
}

// DecodeManifestEnvelope supports one-shot smudge and tests by parsing and decrypting envelopes.
func DecodeManifestEnvelope(raw []byte, kek []byte) ([]byte, int, error) {
	parsed, err := ParseEncryptedManifestHeader(raw)
	if err != nil {
		return nil, 0, err
	}
	plaintext, err := DecryptAesGcmCombined(kek, parsed.Ciphertext, nil)
	if err != nil {
		return nil, 0, err
	}
	return plaintext, parsed.KekEpoch, nil
}

// EncryptAesGcmCombined emits nonce+ciphertext+tag so callers can store one contiguous blob.
// AAD binds optional authenticated context (for example kek-epoch on DEK wraps); pass nil when unused.
func EncryptAesGcmCombined(key []byte, plaintext []byte, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	ciphertextWithTag := gcm.Seal(nil, nonce, plaintext, aad)
	out := make([]byte, 0, len(nonce)+len(ciphertextWithTag))
	out = append(out, nonce...)
	out = append(out, ciphertextWithTag...)
	return out, nil
}

// DecryptAesGcmCombined reads nonce+ciphertext+tag blobs used by replycant manifest encryption.
// AAD must match the value supplied at seal time or authentication fails.
func DecryptAesGcmCombined(key []byte, combined []byte, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(combined) < gcm.NonceSize()+gcm.Overhead() {
		return nil, fmt.Errorf("ciphertext too short")
	}
	nonce := combined[:gcm.NonceSize()]
	ciphertextWithTag := combined[gcm.NonceSize():]
	return gcm.Open(nil, nonce, ciphertextWithTag, aad)
}

// UnwrapKEKFromAgeEnvelope decrypts one age envelope so filters can recover the KEK for an epoch.
func UnwrapKEKFromAgeEnvelope(epochEnvelope []byte, agePrivateKeyBase64 string) ([]byte, error) {
	priv, err := base64.StdEncoding.DecodeString(agePrivateKeyBase64)
	if err != nil {
		return nil, fmt.Errorf("invalid age private key encoding: %w", err)
	}
	if len(priv) != 32 {
		return nil, fmt.Errorf("invalid age private key length: %d", len(priv))
	}

	lines := strings.Split(strings.ReplaceAll(string(epochEnvelope), "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		filtered = append(filtered, line)
	}
	if len(filtered) == 0 || filtered[0] != "age-encryption.org/v1" {
		return nil, fmt.Errorf("invalid age envelope header")
	}

	var payloadCombined []byte
	var fileKey []byte
	for _, line := range filtered[1:] {
		if strings.HasPrefix(line, "-> X25519 ") {
			if fileKey != nil {
				continue
			}
			candidate, stanzaErr := tryRecipientStanza(priv, strings.TrimPrefix(line, "-> X25519 "))
			if stanzaErr == nil && len(candidate) == 32 {
				fileKey = candidate
			}
			continue
		}
		if strings.HasPrefix(line, "payload ") {
			payloadCombined, err = base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(line, "payload ")))
			if err != nil {
				return nil, fmt.Errorf("invalid age payload stanza: %w", err)
			}
		}
	}

	if fileKey == nil {
		return nil, fmt.Errorf("no matching recipient stanza for local age key")
	}
	if len(payloadCombined) == 0 {
		return nil, fmt.Errorf("missing age payload stanza")
	}
	return decryptChaChaCombined(payloadCombined, fileKey)
}

// WrapKEKForAge encrypts a KEK for one age public key in replycant age-envelope format.
func WrapKEKForAge(kek []byte, recipientAgePub []byte) ([]byte, error) {
	return WrapKEKForAgeRecipients(kek, [][]byte{recipientAgePub})
}

// WrapKEKForAgeRecipients encrypts one KEK for multiple age recipients in one envelope payload.
func WrapKEKForAgeRecipients(kek []byte, recipientAgePubs [][]byte) ([]byte, error) {
	if len(recipientAgePubs) == 0 {
		return nil, fmt.Errorf("at least one recipient is required")
	}
	fileKey := make([]byte, 32)
	if _, err := rand.Read(fileKey); err != nil {
		return nil, err
	}
	stanzas := make([]string, 0, len(recipientAgePubs))
	for _, recipientAgePub := range recipientAgePubs {
		ephemeralPriv := make([]byte, 32)
		if _, err := rand.Read(ephemeralPriv); err != nil {
			return nil, err
		}
		ephemeralPub, err := curve25519.X25519(ephemeralPriv, curve25519.Basepoint)
		if err != nil {
			return nil, err
		}
		sharedSecret, err := curve25519.X25519(ephemeralPriv, recipientAgePub)
		if err != nil {
			return nil, err
		}
		wrapKey, err := deriveWrapKey(sharedSecret)
		if err != nil {
			return nil, err
		}
		wrappedFileKey, err := encryptChaChaCombined(wrapKey, fileKey)
		if err != nil {
			return nil, err
		}
		stanzas = append(stanzas, fmt.Sprintf("-> X25519 %s %s", base64.StdEncoding.EncodeToString(ephemeralPub), base64.StdEncoding.EncodeToString(wrappedFileKey)))
	}
	payload, err := encryptChaChaCombined(fileKey, kek)
	if err != nil {
		return nil, err
	}
	lines := make([]string, 0, len(stanzas)+3)
	lines = append(lines, "age-encryption.org/v1")
	lines = append(lines, stanzas...)
	lines = append(lines, "payload "+base64.StdEncoding.EncodeToString(payload), "")
	envelope := strings.Join(lines, "\n")
	return []byte(envelope), nil
}

// DecodeAgePublicKey converts bech32 age recipients into raw 32-byte X25519 public keys.
func DecodeAgePublicKey(agePublicKey string) ([]byte, error) {
	hrp, data, err := bech32.Decode(strings.TrimSpace(agePublicKey))
	if err != nil {
		return nil, err
	}
	if hrp != "age" {
		return nil, fmt.Errorf("invalid age recipient hrp: %s", hrp)
	}
	raw, err := bech32.ConvertBits(data, 5, 8, false)
	if err != nil {
		return nil, err
	}
	if len(raw) != 32 {
		return nil, fmt.Errorf("invalid age recipient length: %d", len(raw))
	}
	return raw, nil
}

// tryRecipientStanza attempts one X25519 recipient stanza and returns the decrypted file key.
func tryRecipientStanza(privateKey []byte, stanza string) ([]byte, error) {
	parts := strings.Fields(stanza)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid recipient stanza")
	}
	ephemeralPub, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("invalid ephemeral public key: %w", err)
	}
	combined, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("invalid wrapped file key: %w", err)
	}
	sharedSecret, err := curve25519.X25519(privateKey, ephemeralPub)
	if err != nil {
		return nil, fmt.Errorf("failed to derive shared secret: %w", err)
	}
	wrapKey, err := deriveWrapKey(sharedSecret)
	if err != nil {
		return nil, err
	}
	return decryptChaChaCombined(combined, wrapKey)
}

// deriveWrapKey reproduces the HKDF contract shared by replycant age envelope implementations.
func deriveWrapKey(sharedSecret []byte) ([]byte, error) {
	reader := hkdf.New(sha256.New, sharedSecret, wrapSalt, wrapInfo)
	key := make([]byte, 32)
	if _, err := io.ReadFull(reader, key); err != nil {
		return nil, fmt.Errorf("failed to derive wrap key: %w", err)
	}
	return key, nil
}

// decryptChaChaCombined decrypts nonce+ciphertext+tag payloads used in age envelope fields.
func decryptChaChaCombined(combined []byte, key []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("failed to build ChaCha20-Poly1305: %w", err)
	}
	nonceSize := aead.NonceSize()
	if len(combined) < nonceSize+aead.Overhead() {
		return nil, fmt.Errorf("combined payload too short")
	}
	nonce := combined[:nonceSize]
	ciphertextWithTag := combined[nonceSize:]
	return aead.Open(nil, nonce, ciphertextWithTag, nil)
}

// encryptChaChaCombined encodes nonce+ciphertext+tag payloads used in age envelope fields.
func encryptChaChaCombined(key []byte, plaintext []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	ciphertextWithTag := aead.Seal(nil, nonce, plaintext, nil)
	out := make([]byte, 0, len(nonce)+len(ciphertextWithTag))
	out = append(out, nonce...)
	out = append(out, ciphertextWithTag...)
	return out, nil
}
