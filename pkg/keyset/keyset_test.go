package keyset

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/curve25519"
)

// TestParseRoundTrip keeps the on-disk KeySet shape stable so gitd and
// the clients read the same fields a writer just stored.
func TestParseRoundTrip(t *testing.T) {
	t.Parallel()
	original := sampleKeySet(t, "iphone-16e-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", TypeDevice)
	encoded, err := Marshal(original)
	require.NoError(t, err)

	parsed, err := Parse(encoded)
	require.NoError(t, err)
	assert.Equal(t, original, parsed)
	assert.NotContains(t, string(encoded), "displayName")
}

// TestParseRejectsAKeySetThatCannotAuthorize keeps a bad file from
// looking like a member of the library.
func TestParseRejectsAKeySetThatCannotAuthorize(t *testing.T) {
	t.Parallel()
	valid := sampleKeySet(t, "iphone", TypeDevice)
	encoded, err := Marshal(valid)
	require.NoError(t, err)

	cases := []struct {
		name string
		raw  string
	}{
		{name: "wrong kind", raw: strings.Replace(string(encoded), "kind: KeySet", "kind: Original", 1)},
		{name: "missing mtls key", raw: strings.Replace(string(encoded), "\n  mtlsPublicKey:", "\n  ignored:", 1)},
		{name: "unknown type", raw: strings.Replace(string(encoded), "type: device", "type: laptop", 1)},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			_, err := Parse([]byte(tt.raw))
			require.Error(t, err)
		})
	}
}

// TestDecryptDisplayNameRejectsASwappedName stops a server that can edit
// plaintext YAML from moving one device's name onto another key.
func TestDecryptDisplayNameRejectsASwappedName(t *testing.T) {
	t.Parallel()
	kek := bytes32(t, 7)
	ks := sampleKeySet(t, "iphone-16e", TypeDevice)
	sealed, err := EncryptDisplayName(kek, 2, ks.Metadata.Name, "Andreas's iPhone 16E")
	require.NoError(t, err)
	ks.Spec.DisplayName = &sealed

	got, err := DecryptDisplayName(kek, ks)
	require.NoError(t, err)
	assert.Equal(t, "Andreas's iPhone 16E", got)

	ks.Metadata.Name = "other-phone"
	_, err = DecryptDisplayName(kek, ks)
	require.Error(t, err)
}

// TestDecryptDisplayNameReportsWhenTheFieldIsAbsent so callers can fall
// back to the slug instead of treating a migrated key set as corrupt.
func TestDecryptDisplayNameReportsWhenTheFieldIsAbsent(t *testing.T) {
	t.Parallel()
	ks := sampleKeySet(t, "iphone-16e", TypeDevice)
	_, err := DecryptDisplayName(bytes32(t, 7), ks)
	require.ErrorIs(t, err, ErrDisplayNameAbsent)
}

func sampleKeySet(t *testing.T, name string, keyType string) KeySet {
	t.Helper()
	mtls := sampleMTLSPublicKey(t, name)
	return KeySet{
		APIVersion: APIVersion,
		Kind:       Kind,
		Metadata:   Metadata{Name: name},
		Spec: Spec{
			Type:          keyType,
			MTLSPublicKey: mtls,
			AgePublicKey:  sampleAgePublicKey(t),
		},
	}
}

func sampleMTLSPublicKey(t *testing.T, comment string) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	line, err := gitcrypt.FormatSSHPublicKey(&key.PublicKey, comment)
	require.NoError(t, err)
	return line
}

func sampleAgePublicKey(t *testing.T) string {
	t.Helper()
	seed := make([]byte, 32)
	_, err := rand.Read(seed)
	require.NoError(t, err)
	public, err := curve25519.X25519(seed, curve25519.Basepoint)
	require.NoError(t, err)
	encoded, err := gitcrypt.EncodeAgePublicKey(public)
	require.NoError(t, err)
	return encoded
}

func bytes32(t *testing.T, fill byte) []byte {
	t.Helper()
	key := make([]byte, 32)
	for i := range key {
		key[i] = fill
	}
	return key
}
