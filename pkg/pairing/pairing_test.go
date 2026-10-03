package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/curve25519"
)

// Builds an age keypair in the same encoding the device identity uses, so the
// tests exercise the real recipient format rather than a stand-in.
func newAgeKeypair(t *testing.T) (publicKey []byte, privateKeyBase64 string) {
	t.Helper()

	privateKey := make([]byte, 32)
	_, err := rand.Read(privateKey)
	require.NoError(t, err)

	publicKey, err = curve25519.X25519(privateKey, curve25519.Basepoint)
	require.NoError(t, err)

	return publicKey, base64.StdEncoding.EncodeToString(privateKey)
}

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

// The happy path: whoever scanned the QR can write a record that only the
// device holding both the pairing secret and its age private key can read.
func TestSealOpenRoundTrip(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	agePublic, agePrivate := newAgeKeypair(t)

	blob, err := Seal(secret, agePublic, testPayload())
	require.NoError(t, err)

	opened, err := Open(secret, agePrivate, blob)
	require.NoError(t, err)
	assert.Equal(t, testPayload(), opened)
}

// The sealed record must not leak its contents to anyone who merely obtains
// the blob, which the discovery API operator does by definition.
func TestSealedBlobLeaksNoPlaintext(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	agePublic, _ := newAgeKeypair(t)
	payload := testPayload()

	blob, err := Seal(secret, agePublic, payload)
	require.NoError(t, err)

	for _, secretValue := range []string{
		payload.HeadscaleURL,
		"BEGIN CERTIFICATE",
	} {
		assert.NotContains(t, string(blob), secretValue,
			"sealed blob must not contain %q in the clear", secretValue)
	}
}

// This is the property the pairing secret exists for. Device public keys are
// published in pubkeys/, so "knows the age key" is not a capability; without
// the secret an attacker must not be able to plant a readable record.
func TestOpenRejectsBlobSealedWithADifferentSecret(t *testing.T) {
	t.Parallel()

	victimSecret, err := NewSecret()
	require.NoError(t, err)
	attackerSecret, err := NewSecret()
	require.NoError(t, err)
	agePublic, agePrivate := newAgeKeypair(t)

	// The attacker knows the device's age public key and forges a record.
	forged, err := Seal(attackerSecret, agePublic, testPayload())
	require.NoError(t, err)

	_, err = Open(victimSecret, agePrivate, forged)
	require.Error(t, err, "a record sealed under another secret must not open")
}

// Holding the pairing secret alone must not be enough. A bystander who
// photographs the QR still cannot read the CA or the control-plane address.
func TestOpenRejectsWrongAgeKey(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	agePublic, _ := newAgeKeypair(t)
	_, otherPrivate := newAgeKeypair(t)

	blob, err := Seal(secret, agePublic, testPayload())
	require.NoError(t, err)

	_, err = Open(secret, otherPrivate, blob)
	require.Error(t, err, "the record must stay sealed without the device age key")
}

// Any modification must be detected rather than yielding a partially trusted
// payload, since the payload decides which CA the device will trust.
func TestOpenRejectsTamperedBlob(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	agePublic, agePrivate := newAgeKeypair(t)

	blob, err := Seal(secret, agePublic, testPayload())
	require.NoError(t, err)

	for _, index := range []int{0, len(blob) / 2, len(blob) - 1} {
		tampered := append([]byte(nil), blob...)
		tampered[index] ^= 0xFF
		_, err := Open(secret, agePrivate, tampered)
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
	agePublic, _ := newAgeKeypair(t)

	first, err := Seal(secret, agePublic, testPayload())
	require.NoError(t, err)
	second, err := Seal(secret, agePublic, testPayload())
	require.NoError(t, err)

	assert.NotEqual(t, first, second)
}

// An incomplete payload would leave the device unable to finish joining, and
// it is cheaper to catch that at the writer than to debug a stuck client.
func TestSealRejectsIncompletePayload(t *testing.T) {
	t.Parallel()

	secret, err := NewSecret()
	require.NoError(t, err)
	agePublic, _ := newAgeKeypair(t)

	complete := testPayload()
	cases := map[string]func(*Payload){
		"no headscale url": func(p *Payload) { p.HeadscaleURL = "" },
		"no ca":            func(p *Payload) { p.CAPEM = "" },
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			payload := complete
			mutate(&payload)
			_, err := Seal(secret, agePublic, payload)
			require.Error(t, err)
		})
	}
}

// A device must reject a record whose CA does not match the fingerprint in the
// hostname it was told to use, so a swapped CA cannot go unnoticed.
func TestPayloadVerifyCALabel(t *testing.T) {
	t.Parallel()

	const caPEM = `-----BEGIN CERTIFICATE-----
MIIBQjCB6KADAgECAgEqMAoGCCqGSM49BAMCMBYxFDASBgNVBAMTC3JlcGx5Y2Fu
dC1jYTAeFw0yNjA0MjAwMDAwMDBaFw0yNzA0MjAwMDAwMDBaMBYxFDASBgNVBAMT
C3JlcGx5Y2FudC1jYTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBe9qUrj9U7h
N+BlYbM2Q09qfB5cj3GmL9j6x2/pRjYKf0Qm2YpP53rUEfCYyYJ3r8uWPtTGC4+E
vR5jS6wS7W6jEzARMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIg
LEj+/WUkDhfmrCRf4r0cNwQ/2M0wXWJmZSp+2FwsKscCIQDKQ2nEAj+8DkOn2h0o
0fJxQzN9Mn5JgKaYz4cK2vW8mA==
-----END CERTIFICATE-----`

	label, err := gitcrypt.CADNSLabel(caPEM)
	require.NoError(t, err)

	host, err := gitcrypt.CATunnelHost(caPEM, "tunnel.replycant.com")
	require.NoError(t, err)

	payload := Payload{
		HeadscaleURL: "https://" + host,
		CAPEM:        caPEM,
	}
	require.NoError(t, payload.VerifyCALabel())

	mismatched := payload
	mismatched.HeadscaleURL = "https://0000000000000000000000000000dead.tunnel.replycant.com"
	require.Error(t, mismatched.VerifyCALabel())

	// The shard component is what lets the relay fleet grow, and it only works
	// because every reader of the fingerprint takes the leftmost label. A check
	// that looked at the whole hostname would reject every real record.
	require.Regexp(t, `^`+label+`\.s\d\d\.`, host, "the shard sits right of the CA label")
	unsharded := payload
	unsharded.HeadscaleURL = "https://" + label + ".tunnel.replycant.com"
	require.NoError(t, unsharded.VerifyCALabel(),
		"the check must depend on the leftmost label only")
}

// Manual mode publishes headscale under the operator's own DNS name, which
// carries no CA fingerprint, so the check must not reject that shape.
func TestPayloadVerifyCALabelSkipsManualHostnames(t *testing.T) {
	t.Parallel()

	payload := testPayload()
	payload.HeadscaleURL = "https://replycant.example.com:8443"
	require.NoError(t, payload.VerifyCALabel())
}
