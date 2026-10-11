package pairing

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func testPayload() Payload {
	return Payload{
		HeadscaleURL: "https://8d121a007a4ae234d4c6abac034e3094.tunnel.replycant.com",
		CAPEM:        "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
	}
}

// The record travels through a hosted discovery API and may be shown as a QR,
// so it must carry no credential at all. A newly paired device mints its own
// tailnet key from hsproxy with its certificate, which is already in pubkeys/
// by the time it joins. The wire shape is shared with the Swift and TypeScript
// readers, so it is pinned field by field.
func TestPayloadCarriesOnlyTheCAAndControlURL(t *testing.T) {
	t.Parallel()

	encoded, err := json.Marshal(testPayload())
	require.NoError(t, err)
	var fields map[string]any
	require.NoError(t, json.Unmarshal(encoded, &fields))

	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	assert.ElementsMatch(t, []string{"headscale_url", "ca_pem"}, keys)
}

// The happy path: whoever scanned the QR can write a record that only a
// holder of the same pairing secret can open.
func TestSealOpenRoundTrip(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	blob, err := Seal(secret, testPayload())
	require.NoError(t, err)

	opened, err := Open(secret, blob)
	require.NoError(t, err)
	assert.Equal(t, testPayload(), opened)
}

// The sealed record must not leak its contents to anyone who merely obtains
// the blob, which the discovery API operator does by definition.
func TestSealedBlobLeaksNoPlaintext(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	payload := testPayload()

	blob, err := Seal(secret, payload)
	require.NoError(t, err)

	for _, secretValue := range []string{
		payload.HeadscaleURL,
		"BEGIN CERTIFICATE",
	} {
		assert.NotContains(t, string(blob), secretValue,
			"sealed blob must not contain %q in the clear", secretValue)
	}
}

// This is the property the pairing secret exists for. The discovery slot
// travels in the clear, so without the secret an attacker must not be able
// to plant a record the waiting device will open.
func TestOpenRejectsBlobSealedWithADifferentSecret(t *testing.T) {
	t.Parallel()

	victimSecret, err := NewSecret()
	require.NoError(t, err)
	attackerSecret, err := NewSecret()
	require.NoError(t, err)

	forged, err := Seal(attackerSecret, testPayload())
	require.NoError(t, err)

	_, err = Open(victimSecret, forged)
	require.Error(t, err, "a record sealed under another secret must not open")
}

// The slot is associated data, so copying a valid record onto another slot
// must not make it open, even under the wrap key that sealed it. That is
// what stops a record from being relocated and replayed against another
// pairing attempt.
func TestOpenRejectsRecordMovedToAnotherSlot(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	other, err := NewSecret()
	require.NoError(t, err)

	blob, err := Seal(secret, testPayload())
	require.NoError(t, err)

	wrapKey := secret.wrapKey()
	_, err = gitcrypt.DecryptAesGcmCombined(wrapKey[:], blob, associatedData(other))
	require.Error(t, err, "a record must not open under another slot")

	plaintext, err := gitcrypt.DecryptAesGcmCombined(wrapKey[:], blob, associatedData(secret))
	require.NoError(t, err)
	assert.Contains(t, string(plaintext), testPayload().HeadscaleURL)
}

// Any modification must be detected rather than yielding a partially trusted
// payload, since the payload decides which CA the device will trust.
func TestOpenRejectsTamperedBlob(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	blob, err := Seal(secret, testPayload())
	require.NoError(t, err)

	for _, index := range []int{0, len(blob) / 2, len(blob) - 1} {
		tampered := append([]byte(nil), blob...)
		tampered[index] ^= 0xFF
		_, err := Open(secret, tampered)
		require.Error(t, err, "flipping byte %d must be detected", index)
	}
}

// The slot is a DNS label in the discovery hostname, so it has to be a valid
// label and short enough to fit.
func TestSlotIsAValidDNSLabel(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	slot := secret.Slot()
	assert.Len(t, slot, slotHexChars)
	assert.LessOrEqual(t, len(slot), 63)
	assert.Equal(t, strings.ToLower(slot), slot)
	for _, character := range slot {
		assert.True(t, strings.ContainsRune("0123456789abcdef", character),
			"slot must be hex, found %q", character)
	}
}

// A fresh secret per pairing attempt is what makes the slot unlinkable to any
// long-lived identity and stops a stale record from being replayed.
func TestDistinctSecretsProduceDistinctSlots(t *testing.T) {
	t.Parallel()

	first, err := NewSecret()
	require.NoError(t, err)
	second, err := NewSecret()
	require.NoError(t, err)

	assert.NotEqual(t, first.Slot(), second.Slot())
}

// Both sides derive the slot independently, so the derivation must be a pure
// function of the secret.
func TestSlotIsDeterministic(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	parsed, err := ParseSecret(secret.String())
	require.NoError(t, err)
	assert.Equal(t, secret.Slot(), parsed.Slot())
}

// The slot travels in the clear as a hostname. Learning it must not reveal the
// key that authenticates records, which is why the two are domain-separated.
func TestSlotDoesNotRevealWrapKey(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	slot := secret.Slot()
	wrapKey := secret.wrapKey()

	assert.NotContains(t, base64.StdEncoding.EncodeToString(wrapKey[:]), slot)
	assert.NotEqual(t, slot, base64.RawURLEncoding.EncodeToString(wrapKey[:]))
}

// The secret crosses to the server as QR text, so its encoding has to survive
// a string round trip exactly.
func TestSecretStringRoundTrip(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	parsed, err := ParseSecret(secret.String())
	require.NoError(t, err)
	assert.Equal(t, secret, parsed)
}

// A truncated or padded secret is a sign of a corrupted scan; accepting it
// would produce a slot nobody ever wrote to and a confusing timeout.
func TestParseSecretRejectsWrongLength(t *testing.T) {
	t.Parallel()

	cases := []string{
		"",
		"short",
		base64.RawURLEncoding.EncodeToString(make([]byte, SecretBytes-1)),
		base64.RawURLEncoding.EncodeToString(make([]byte, SecretBytes+1)),
		"!!!not base64!!!",
	}

	for _, encoded := range cases {
		_, err := ParseSecret(encoded)
		require.Error(t, err, "ParseSecret(%q) must fail", encoded)
	}
}

// Sealing must be non-deterministic so two records for the same payload are
// not byte-identical, which would let an observer correlate pairing attempts.
func TestSealIsNonDeterministic(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	first, err := Seal(secret, testPayload())
	require.NoError(t, err)
	second, err := Seal(secret, testPayload())
	require.NoError(t, err)

	assert.NotEqual(t, first, second)
}

// An incomplete payload would leave the device unable to finish joining, and
// it is cheaper to catch that at the writer than to debug a stuck client.
func TestSealRejectsIncompletePayload(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)

	complete := testPayload()
	cases := map[string]func(*Payload){
		"no headscale url": func(p *Payload) { p.HeadscaleURL = "" },
		"no ca":            func(p *Payload) { p.CAPEM = "" },
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			payload := complete
			mutate(&payload)
			_, err := Seal(secret, payload)
			require.Error(t, err)
		})
	}
}
