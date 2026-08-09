package gitcrypt

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// RecoveryGoldenFixture pins one exported bundle so every runtime keeps parsing identical.
type RecoveryGoldenFixture struct {
	Password  string            `json:"password"`
	Envelope  RecoveryEnvelope  `json:"envelope"`
	Plaintext RecoveryPlaintext `json:"plaintext"`
}

// TestDecryptRecoveryEnvelopeMatchesGoldenFixture keeps Go decryption aligned with iOS envelope output.
func TestDecryptRecoveryEnvelopeMatchesGoldenFixture(t *testing.T) {
	t.Parallel()
	fixture := loadRecoveryGoldenFixture(t)

	rawEnvelope, err := json.Marshal(fixture.Envelope)
	require.NoError(t, err)

	decrypted, err := DecryptRecoveryEnvelope(rawEnvelope, fixture.Password)
	require.NoError(t, err)
	require.Equal(t, fixture.Plaintext, decrypted)
}

// TestDecryptRecoveryEnvelopeRejectsWrongPassword ensures offline brute-force attempts fail closed per try.
func TestDecryptRecoveryEnvelopeRejectsWrongPassword(t *testing.T) {
	t.Parallel()
	fixture := loadRecoveryGoldenFixture(t)

	rawEnvelope, err := json.Marshal(fixture.Envelope)
	require.NoError(t, err)

	_, err = DecryptRecoveryEnvelope(rawEnvelope, "wrong password")
	require.Error(t, err)
}

// loadRecoveryGoldenFixture reads the shared repository fixture consumed by both Swift and Go tests.
func loadRecoveryGoldenFixture(t *testing.T) RecoveryGoldenFixture {
	t.Helper()
	path := filepath.Join("..", "..", "testdata", "recovery", "recovery_bundle_golden.json")
	raw, err := os.ReadFile(path)
	require.NoError(t, err)

	var fixture RecoveryGoldenFixture
	require.NoError(t, json.Unmarshal(raw, &fixture))
	return fixture
}
