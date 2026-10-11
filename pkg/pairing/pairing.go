// Package pairing implements the sealed record a device fetches from the
// hosted discovery API to learn how to reach its own headscale.
//
// The record holds the deployment CA and the control-plane URL. Neither is a
// secret: the device is about to pin that CA, and the URL is a hostname
// derived from it. What the record needs is authenticity. A device that has
// never paired holds no trust anchor, the discovery slot travels in the clear
// as a DNS hostname, and anyone who can write to the discovery API could
// otherwise plant a record naming their own CA and enroll the device into
// their tailnet.
//
// The pairing secret closes that gap. It is generated fresh by the pairing
// device, shown only in the QR code, and so is only known to whoever was
// physically in front of the screen and to gitd, which receives it from the
// already-paired device that scanned the QR. Two values are derived from it,
// with domain separation so that publishing one does not expose the other:
//
//   - the slot, which addresses the record and is unlinkable to any long-lived
//     identity because it rotates per attempt
//   - the wrap key, which authenticates the record
//
// The record is one AES-GCM ciphertext under the wrap key. The slot is bound
// as associated data, so a valid record cannot be relocated to another slot.
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

// What a pairing device needs in order to join the tailnet.
//
// gitd's address is not here: every client already knows it
// (pkg/tailnetaddr). Putting a name in the record would let a QR and a
// certificate SAN drift, and the first device has no pairing record at all.
//
// No credential is here either. The authorizing device commits the new
// device's key to pubkeys/ before publishing the record, so the new device
// mints its own single-use tailnet key from hsproxy with its certificate, the
// same way it does whenever headscale forgets it later. The record is
// authenticated under the pairing secret rather than encrypted to that key:
// nothing in it is confidential.
type Payload struct {
	HeadscaleURL string `json:"headscale_url"`
	CAPEM        string `json:"ca_pem"`
}

// Rejects a payload that would leave the device unable to finish joining. It is
// far cheaper to catch this at the writer than to debug a client that sits at
// "waiting for authorization" forever.
func (p Payload) validate() error {
	missing := make([]string, 0, 2)
	if strings.TrimSpace(p.HeadscaleURL) == "" {
		missing = append(missing, "headscale_url")
	}
	if strings.TrimSpace(p.CAPEM) == "" {
		missing = append(missing, "ca_pem")
	}
	if len(missing) > 0 {
		return fmt.Errorf("pairing payload is missing %s", strings.Join(missing, ", "))
	}
	return nil
}

// Builds the record for a device, addressed and authenticated by the secret.
//
// One ciphertext is enough. The payload names a CA and a URL derived from
// that CA, so there is nothing confidential to hide from someone who already
// holds the secret, and the secret is what stops anyone else from writing a
// record this device will open.
func Seal(secret Secret, payload Payload) ([]byte, error) {
	if err := payload.validate(); err != nil {
		return nil, err
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode pairing payload: %w", err)
	}

	wrapKey := secret.wrapKey()
	sealed, err := gitcrypt.EncryptAesGcmCombined(wrapKey[:], payloadJSON, associatedData(secret))
	if err != nil {
		return nil, fmt.Errorf("seal pairing record: %w", err)
	}
	return sealed, nil
}

// Opens a record fetched from the discovery API.
//
// The pairing secret is the whole credential: it proves the record was
// written by whoever scanned this device's QR.
func Open(secret Secret, sealed []byte) (Payload, error) {
	wrapKey := secret.wrapKey()
	payloadJSON, err := gitcrypt.DecryptAesGcmCombined(wrapKey[:], sealed, associatedData(secret))
	if err != nil {
		return Payload{}, fmt.Errorf("pairing record did not open under this pairing secret: %w", err)
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
