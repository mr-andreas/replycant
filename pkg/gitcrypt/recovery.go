package gitcrypt

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"golang.org/x/crypto/pbkdf2"
)

const (
	// RecoveryEnvelopeVersion keeps iOS and Go recovery payload parsing fail-closed across upgrades.
	RecoveryEnvelopeVersion = 1
	// RecoveryKDFAlgorithm is the only accepted KDF for recovery-key envelopes.
	RecoveryKDFAlgorithm = "PBKDF2-HMAC-SHA256"
	// RecoveryCipherAlgorithm is the only accepted cipher for recovery-key envelopes.
	RecoveryCipherAlgorithm = "AES-256-GCM"
)

// RecoveryKDF describes key derivation parameters embedded in recovery envelopes.
type RecoveryKDF struct {
	Alg        string `json:"alg"`
	Iterations int    `json:"iterations"`
	Salt       string `json:"salt"`
}

// RecoveryEnvelope carries encrypted recovery bundle fields exported by iOS.
type RecoveryEnvelope struct {
	V          int         `json:"v"`
	KDF        RecoveryKDF `json:"kdf"`
	Cipher     string      `json:"cipher"`
	Nonce      string      `json:"nonce"`
	Ciphertext string      `json:"ciphertext"`
}

// RecoveryPlaintext contains every field needed to re-establish repository access after key loss.
type RecoveryPlaintext struct {
	Version           int    `json:"version"`
	Label             string `json:"label"`
	UUID              string `json:"uuid"`
	Created           string `json:"created"`
	DiscoveryURL      string `json:"discovery_url"`
	CASHA256          string `json:"ca_sha256"`
	P256PrivateKeyPEM string `json:"p256_private_key"`
	AgePrivateKey     string `json:"age_private_key"`
}

// DecryptRecoveryEnvelope parses and decrypts an exported recovery envelope.
func DecryptRecoveryEnvelope(envelopeJSON []byte, password string) (RecoveryPlaintext, error) {
	var envelope RecoveryEnvelope
	if err := json.Unmarshal(envelopeJSON, &envelope); err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("parse recovery envelope: %w", err)
	}
	return decryptRecoveryEnvelope(envelope, password)
}

// decryptRecoveryEnvelope validates algorithm metadata and decrypts into typed plaintext.
func decryptRecoveryEnvelope(envelope RecoveryEnvelope, password string) (RecoveryPlaintext, error) {
	if envelope.V != RecoveryEnvelopeVersion {
		return RecoveryPlaintext{}, fmt.Errorf("unsupported recovery envelope version %d", envelope.V)
	}
	if envelope.Cipher != RecoveryCipherAlgorithm {
		return RecoveryPlaintext{}, fmt.Errorf("unsupported recovery cipher %q", envelope.Cipher)
	}
	if envelope.KDF.Alg != RecoveryKDFAlgorithm {
		return RecoveryPlaintext{}, fmt.Errorf("unsupported recovery kdf %q", envelope.KDF.Alg)
	}
	if envelope.KDF.Iterations <= 0 {
		return RecoveryPlaintext{}, fmt.Errorf("invalid recovery kdf iterations %d", envelope.KDF.Iterations)
	}

	salt, err := base64.StdEncoding.DecodeString(envelope.KDF.Salt)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("decode recovery salt: %w", err)
	}
	nonce, err := base64.StdEncoding.DecodeString(envelope.Nonce)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("decode recovery nonce: %w", err)
	}
	ciphertext, err := base64.StdEncoding.DecodeString(envelope.Ciphertext)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("decode recovery ciphertext: %w", err)
	}

	key := pbkdf2.Key([]byte(password), salt, envelope.KDF.Iterations, 32, sha256.New)
	block, err := aes.NewCipher(key)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("create recovery aes block: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("create recovery gcm: %w", err)
	}

	if len(nonce) != aead.NonceSize() {
		return RecoveryPlaintext{}, fmt.Errorf("invalid recovery nonce size %d", len(nonce))
	}
	if len(ciphertext) < aead.NonceSize() {
		return RecoveryPlaintext{}, fmt.Errorf("invalid recovery ciphertext length %d", len(ciphertext))
	}
	if string(ciphertext[:aead.NonceSize()]) != string(nonce) {
		return RecoveryPlaintext{}, fmt.Errorf("recovery nonce mismatch between header and ciphertext")
	}

	plaintextJSON, err := aead.Open(nil, ciphertext[:aead.NonceSize()], ciphertext[aead.NonceSize():], nil)
	if err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("decrypt recovery envelope: %w", err)
	}

	var plaintext RecoveryPlaintext
	if err := json.Unmarshal(plaintextJSON, &plaintext); err != nil {
		return RecoveryPlaintext{}, fmt.Errorf("parse recovery plaintext: %w", err)
	}
	return plaintext, nil
}
