// Package pairing implements the sealed record a device fetches from the
// hosted discovery API to learn how to reach its own headscale.
//
// The problem this solves: a device that has never been paired has no trust
// anchor. It does not know the CA, so nothing in the record can be verified
// with a signature it already trusts. Meanwhile the discovery slot travels in
// the clear as a DNS hostname, and device public keys are published in the
// repository's pubkeys/ directory, so neither the slot nor the device key is a
// secret. Encrypting to the device's public key therefore gives confidentiality
// but no writer authentication: anyone could plant a record naming their own CA
// and headscale, and the device would enroll into the attacker's tailnet.
//
// The pairing secret closes that gap. It is generated fresh by the pairing
// device, shown only in the QR code, and so is only known to whoever was
// physically in front of the screen. Two values are derived from it, with
// domain separation so that publishing one does not expose the other:
//
//   - the slot, which addresses the record and is unlinkable to any long-lived
//     identity because it rotates per attempt
//   - the wrap key, which authenticates the record
//
// Records carry two layers. The inner layer is encrypted to the device's age
// public key, so a bystander who photographed the QR still cannot read the
// contents. The outer layer is an AEAD under the wrap key, so a party who knows
// the slot and the device key still cannot forge a record. Both layers bind the
// slot as associated data, so a valid record cannot be relocated to another
// slot.
package pairing

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"golang.org/x/crypto/hkdf"
)

const (
	// Size of the pairing secret. 32 bytes is far beyond brute force, which is
	// affordable because the secret only ever travels inside a QR code.
	SecretBytes = 32

	// Hex characters in a slot label. 16 bytes of digest keeps slots
	// collision-free in practice while fitting well inside the 63-octet DNS
	// label limit.
	slotHexChars = 32

	// Envelope version, so a future format change is a clear error on old
	// clients rather than a decryption failure that looks like corruption.
	envelopeVersion = 1
)

// Domain-separation labels. Deriving the slot and the wrap key with different
// info strings is what makes it safe to publish the slot as a hostname while
// the wrap key still authenticates records.
var (
	hkdfSalt     = []byte("replycant/discovery/v1")
	slotInfo     = []byte("replycant/discovery-slot/v1")
	wrapKeyInfo  = []byte("replycant/discovery-wrap/v1")
	contentKeyID = []byte("replycant/discovery-content/v1")
)

// The out-of-band secret that authenticates a discovery record. Transported
// only in the pairing QR code, held in memory, and never persisted or sent to
// the discovery API.
type Secret [SecretBytes]byte

// Generates a fresh secret. Callers must create one per pairing attempt so
// slots stay unlinkable and old records cannot be replayed.
func NewSecret() (Secret, error) {
	var secret Secret
	if _, err := rand.Read(secret[:]); err != nil {
		return Secret{}, fmt.Errorf("generate pairing secret: %w", err)
	}
	return secret, nil
}

// Encodes the secret for the QR payload. Raw URL base64 avoids padding and the
// characters that tend to be mangled when a value ends up in a URL.
func (s Secret) String() string {
	return base64.RawURLEncoding.EncodeToString(s[:])
}

// Parses a secret scanned from a QR code. A wrong length is rejected rather
// than zero-padded, because a truncated scan would otherwise produce a slot
// nobody ever wrote to and surface as an unexplained pairing timeout.
func ParseSecret(encoded string) (Secret, error) {
	trimmed := strings.TrimSpace(encoded)
	if trimmed == "" {
		return Secret{}, errors.New("pairing secret is empty")
	}
	raw, err := base64.RawURLEncoding.DecodeString(trimmed)
	if err != nil {
		return Secret{}, fmt.Errorf("pairing secret is not valid base64url: %w", err)
	}
	if len(raw) != SecretBytes {
		return Secret{}, fmt.Errorf("pairing secret must be %d bytes, got %d", SecretBytes, len(raw))
	}
	var secret Secret
	copy(secret[:], raw)
	return secret, nil
}

// Derives the discovery slot label, used as the subdomain the record is stored
// under. Both the writer and the reader derive it independently from the
// secret, so it never has to be transmitted.
func (s Secret) Slot() string {
	derived := s.derive(slotInfo, slotHexChars/2)
	return hex.EncodeToString(derived)
}

// Derives the key that authenticates a record under this secret.
func (s Secret) wrapKey() [32]byte {
	var key [32]byte
	copy(key[:], s.derive(wrapKeyInfo, 32))
	return key
}

// Expands the secret into an independent key for one purpose.
func (s Secret) derive(info []byte, length int) []byte {
	reader := hkdf.New(sha256.New, s[:], hkdfSalt, info)
	out := make([]byte, length)
	if _, err := io.ReadFull(reader, out); err != nil {
		// HKDF-Expand cannot fail for these lengths; a failure here would mean
		// the crypto library itself is broken.
		panic(fmt.Sprintf("pairing: HKDF expansion failed: %v", err))
	}
	return out
}

// What a pairing device needs in order to join the tailnet and then reach gitd.
type Payload struct {
	HeadscaleURL    string `json:"headscale_url"`
	CAPEM           string `json:"ca_pem"`
	PreauthKey      string `json:"preauth_key"`
	GitdTailnetName string `json:"gitd_tailnet_name"`
	BaseDomain      string `json:"base_domain"`
}

// Rejects a payload that would leave the device unable to finish joining. It is
// far cheaper to catch this at the writer than to debug a client that sits at
// "waiting for authorization" forever.
func (p Payload) validate() error {
	missing := make([]string, 0, 5)
	if strings.TrimSpace(p.HeadscaleURL) == "" {
		missing = append(missing, "headscale_url")
	}
	if strings.TrimSpace(p.CAPEM) == "" {
		missing = append(missing, "ca_pem")
	}
	if strings.TrimSpace(p.PreauthKey) == "" {
		missing = append(missing, "preauth_key")
	}
	if strings.TrimSpace(p.GitdTailnetName) == "" {
		missing = append(missing, "gitd_tailnet_name")
	}
	if strings.TrimSpace(p.BaseDomain) == "" {
		missing = append(missing, "base_domain")
	}
	if len(missing) > 0 {
		return fmt.Errorf("pairing payload is missing %s", strings.Join(missing, ", "))
	}
	return nil
}

// Confirms the delivered CA is the one the headscale hostname commits to.
//
// In tunnel mode the hostname's first label is a fingerprint of the CA, which
// gives the device a second, independent check that the record it just opened
// names the CA it is about to trust. Manual-mode hostnames carry no
// fingerprint, so there is nothing to compare and the check passes.
func (p Payload) VerifyCALabel() error {
	parsed, err := url.Parse(strings.TrimSpace(p.HeadscaleURL))
	if err != nil {
		return fmt.Errorf("headscale URL is not a valid URL: %w", err)
	}
	hostname := parsed.Hostname()
	if hostname == "" {
		return fmt.Errorf("headscale URL has no hostname: %q", p.HeadscaleURL)
	}

	firstLabel := hostname
	if index := strings.Index(hostname, "."); index >= 0 {
		firstLabel = hostname[:index]
	}
	if !isCALabelShaped(firstLabel) {
		// Manual exposure: the operator's own DNS name commits to nothing.
		return nil
	}

	expected, err := gitcrypt.CADNSLabel(p.CAPEM)
	if err != nil {
		return fmt.Errorf("compute CA label: %w", err)
	}
	if !strings.EqualFold(expected, firstLabel) {
		return fmt.Errorf("delivered CA does not match the headscale hostname: expected label %q, got %q",
			expected, firstLabel)
	}
	return nil
}

// Reports whether a hostname label has the shape of a CA fingerprint, which is
// how tunnel hostnames are told apart from operator-chosen ones.
func isCALabelShaped(label string) bool {
	if len(label) != slotHexChars {
		return false
	}
	_, err := hex.DecodeString(label)
	return err == nil
}

// The stored record, before the outer authentication layer is applied. Kept as
// JSON so a stored record stays inspectable during development and so the
// version is readable without a key.
type envelope struct {
	Version    int    `json:"v"`
	AgeWrapped string `json:"age"`
	Payload    string `json:"payload"`
}

// Builds the record for a device, addressed by the secret's slot.
//
// deviceAgePublicKey is the raw 32-byte X25519 key from the device's identity,
// which is what the pairing QR carries as age_pubkey.
func Seal(secret Secret, deviceAgePublicKey []byte, payload Payload) ([]byte, error) {
	if err := payload.validate(); err != nil {
		return nil, err
	}
	if len(deviceAgePublicKey) != 32 {
		return nil, fmt.Errorf("device age public key must be 32 bytes, got %d", len(deviceAgePublicKey))
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode pairing payload: %w", err)
	}

	// A fresh content key per record, wrapped to the device. This keeps the
	// age envelope doing the one job it is already trusted with elsewhere in
	// the codebase: protecting a 32-byte key.
	contentKey := make([]byte, 32)
	if _, err := rand.Read(contentKey); err != nil {
		return nil, fmt.Errorf("generate content key: %w", err)
	}

	ageWrapped, err := gitcrypt.WrapKEKForAge(contentKey, deviceAgePublicKey)
	if err != nil {
		return nil, fmt.Errorf("wrap content key for device: %w", err)
	}

	slotAAD := associatedData(secret)
	sealedPayload, err := gitcrypt.EncryptAesGcmCombined(contentKey, payloadJSON, slotAAD)
	if err != nil {
		return nil, fmt.Errorf("encrypt pairing payload: %w", err)
	}

	inner, err := json.Marshal(envelope{
		Version:    envelopeVersion,
		AgeWrapped: base64.StdEncoding.EncodeToString(ageWrapped),
		Payload:    base64.StdEncoding.EncodeToString(sealedPayload),
	})
	if err != nil {
		return nil, fmt.Errorf("encode pairing envelope: %w", err)
	}

	wrapKey := secret.wrapKey()
	sealed, err := gitcrypt.EncryptAesGcmCombined(wrapKey[:], inner, slotAAD)
	if err != nil {
		return nil, fmt.Errorf("seal pairing envelope: %w", err)
	}
	return sealed, nil
}

// Opens a record fetched from the discovery API.
//
// Both the pairing secret and the device's age private key are required: the
// secret proves the record came from whoever scanned the QR, and the age key
// proves this is the device the record was written for.
func Open(secret Secret, deviceAgePrivateKeyBase64 string, sealed []byte) (Payload, error) {
	wrapKey := secret.wrapKey()
	slotAAD := associatedData(secret)

	inner, err := gitcrypt.DecryptAesGcmCombined(wrapKey[:], sealed, slotAAD)
	if err != nil {
		return Payload{}, fmt.Errorf("pairing record did not open under this pairing secret: %w", err)
	}

	var parsed envelope
	if err := json.Unmarshal(inner, &parsed); err != nil {
		return Payload{}, fmt.Errorf("decode pairing envelope: %w", err)
	}
	if parsed.Version != envelopeVersion {
		return Payload{}, fmt.Errorf("unsupported pairing envelope version %d (expected %d)",
			parsed.Version, envelopeVersion)
	}

	ageWrapped, err := base64.StdEncoding.DecodeString(parsed.AgeWrapped)
	if err != nil {
		return Payload{}, fmt.Errorf("decode wrapped content key: %w", err)
	}
	sealedPayload, err := base64.StdEncoding.DecodeString(parsed.Payload)
	if err != nil {
		return Payload{}, fmt.Errorf("decode sealed payload: %w", err)
	}

	contentKey, err := gitcrypt.UnwrapKEKFromAgeEnvelope(ageWrapped, deviceAgePrivateKeyBase64)
	if err != nil {
		return Payload{}, fmt.Errorf("unwrap content key with the device age key: %w", err)
	}

	payloadJSON, err := gitcrypt.DecryptAesGcmCombined(contentKey, sealedPayload, slotAAD)
	if err != nil {
		return Payload{}, fmt.Errorf("decrypt pairing payload: %w", err)
	}

	var payload Payload
	if err := json.Unmarshal(payloadJSON, &payload); err != nil {
		return Payload{}, fmt.Errorf("decode pairing payload: %w", err)
	}
	if err := payload.validate(); err != nil {
		return Payload{}, err
	}
	return payload, nil
}

// Binds a record to its slot so a valid record cannot be relocated to a
// different slot and replayed against another pairing attempt.
func associatedData(secret Secret) []byte {
	return append(append([]byte(nil), contentKeyID...), []byte(secret.Slot())...)
}
