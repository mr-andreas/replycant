package gitcrypt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A DNS label is capped at 63 octets, so the full 64-character SHA-256 hex
// digest cannot be used directly. This is the whole reason the helper exists,
// and the constraint is easy to reintroduce, so pin it.
func TestCADNSLabelFitsInADNSLabel(t *testing.T) {
	t.Parallel()

	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	assert.LessOrEqual(t, len(label), 63, "label must fit in a DNS label")
	assert.Len(t, label, caDNSLabelHexChars)
}

// The label has to be derivable independently by the tunnel service from a
// certificate alone, so pin it to a plain prefix of the DER digest rather than
// anything requiring shared state.
func TestCADNSLabelIsPrefixOfDERDigest(t *testing.T) {
	t.Parallel()

	block, _ := pem.Decode([]byte(testCAPEM))
	require.NotNil(t, block)
	digest := sha256.Sum256(block.Bytes)
	expected := hex.EncodeToString(digest[:])[:caDNSLabelHexChars]

	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	assert.Equal(t, expected, label)
}

// The label must agree with ComputeCAHash, because the same CA is identified by
// the full hash in QR payloads and by this label in tunnel hostnames. A drift
// between them would strand devices.
func TestCADNSLabelMatchesComputeCAHashPrefix(t *testing.T) {
	t.Parallel()

	fullHash, err := ComputeCAHash(testCAPEM)
	require.NoError(t, err)
	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)

	assert.True(t, strings.HasPrefix(fullHash, label))
}

// Labels are used in hostnames, which are case-insensitive and frequently
// normalized in transit, so the output must already be lowercase.
func TestCADNSLabelIsLowercase(t *testing.T) {
	t.Parallel()

	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	assert.Equal(t, strings.ToLower(label), label)
}

// Formatting differences in the PEM must not change which tunnel hostname a
// deployment registers.
func TestCADNSLabelIgnoresPEMFormatting(t *testing.T) {
	t.Parallel()

	base, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	variant, err := CADNSLabel(strings.ReplaceAll(testCAPEM, "\n", "\n\n"))
	require.NoError(t, err)
	assert.Equal(t, base, variant)
}

// Malformed input must fail loudly rather than yield a label that would send
// the deployment to some other subdomain.
func TestCADNSLabelRejectsInvalidPEM(t *testing.T) {
	t.Parallel()

	_, err := CADNSLabel("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----")
	require.Error(t, err)
}

// The tunnel service receives a DER chain rather than PEM, so it needs a
// matching derivation that cannot drift from the PEM one.
func TestCADNSLabelFromDERMatchesPEM(t *testing.T) {
	t.Parallel()

	block, _ := pem.Decode([]byte(testCAPEM))
	require.NotNil(t, block)

	fromPEM, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	assert.Equal(t, fromPEM, CADNSLabelFromDER(block.Bytes))
}
