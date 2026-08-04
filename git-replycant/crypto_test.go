package main

import (
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseCurrentEpoch verifies epoch parsing accepts valid values and rejects malformed input.
func TestParseCurrentEpoch(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		input   string
		want    int
		wantErr bool
	}{
		{name: "one", input: "1", want: 1},
		{name: "trim whitespace", input: "  42\n", want: 42},
		{name: "empty", input: "", wantErr: true},
		{name: "zero", input: "0", wantErr: true},
		{name: "negative", input: "-1", wantErr: true},
		{name: "nonnumeric", input: "abc", wantErr: true},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := gitcrypt.ParseCurrentEpoch([]byte(tt.input))
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestIsEncryptedManifest verifies header detection so decryptors can reject plaintext.
func TestIsEncryptedManifest(t *testing.T) {
	t.Parallel()
	assert.True(t, gitcrypt.IsEncryptedManifest([]byte("REPLYCANT-ENC-V1\nkek-epoch: 1\n---\nabc")))
	assert.False(t, gitcrypt.IsEncryptedManifest([]byte("apiVersion: media.replycant.com/v1alpha1")))
	assert.False(t, gitcrypt.IsEncryptedManifest([]byte{}))
}

// TestParseEncryptedManifestHeader validates envelope parsing and metadata error handling.
func TestParseEncryptedManifestHeader(t *testing.T) {
	t.Parallel()
	payload := []byte("ciphertext")
	raw := append([]byte("REPLYCANT-ENC-V1\nkek-epoch: 7\n---\n"), payload...)
	parsed, err := gitcrypt.ParseEncryptedManifestHeader(raw)
	require.NoError(t, err)
	assert.Equal(t, 7, parsed.KekEpoch)
	assert.Equal(t, payload, parsed.Ciphertext)

	_, err = gitcrypt.ParseEncryptedManifestHeader([]byte("REPLYCANT-ENC-V1\nkek-epoch: 7\nno-delimiter"))
	require.Error(t, err)

	_, err = gitcrypt.ParseEncryptedManifestHeader([]byte("REPLYCANT-ENC-V1\n---\npayload"))
	require.Error(t, err)

	_, err = gitcrypt.ParseEncryptedManifestHeader([]byte("REPLYCANT-ENC-V1\nkek-epoch: nope\n---\npayload"))
	require.Error(t, err)
}

// TestAesGcmRoundtrip ensures combined nonce+ciphertext blobs decrypt only with the correct key.
func TestAesGcmRoundtrip(t *testing.T) {
	t.Parallel()
	key := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("hello world")
	combined, err := gitcrypt.EncryptAesGcmCombined(key, plaintext, nil)
	require.NoError(t, err)

	decrypted, err := gitcrypt.DecryptAesGcmCombined(key, combined, nil)
	require.NoError(t, err)
	assert.Equal(t, plaintext, decrypted)

	wrongKey := []byte("fedcba9876543210fedcba9876543210")
	_, err = gitcrypt.DecryptAesGcmCombined(wrongKey, combined, nil)
	require.Error(t, err)

	_, err = gitcrypt.DecryptAesGcmCombined(key, combined[:5], nil)
	require.Error(t, err)
}

// TestManifestEnvelopeRoundtrip verifies manifest envelope helpers preserve plaintext and epoch.
func TestManifestEnvelopeRoundtrip(t *testing.T) {
	t.Parallel()
	key := []byte("0123456789abcdef0123456789abcdef")
	plaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n")
	epoch := 3

	encrypted, err := gitcrypt.EncryptManifestEnvelope(plaintext, key, epoch)
	require.NoError(t, err)
	assert.True(t, gitcrypt.IsEncryptedManifest(encrypted))
	assert.Contains(t, string(encrypted), "REPLYCANT-ENC-V1\n")

	decrypted, parsedEpoch, err := gitcrypt.DecodeManifestEnvelope(encrypted, key)
	require.NoError(t, err)
	assert.Equal(t, plaintext, decrypted)
	assert.Equal(t, epoch, parsedEpoch)
}
