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

const testCAPEM = `-----BEGIN CERTIFICATE-----
MIIBQjCB6KADAgECAgEqMAoGCCqGSM49BAMCMBYxFDASBgNVBAMTC3JlcGx5Y2Fu
dC1jYTAeFw0yNjA0MjAwMDAwMDBaFw0yNzA0MjAwMDAwMDBaMBYxFDASBgNVBAMT
C3JlcGx5Y2FudC1jYTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBe9qUrj9U7h
N+BlYbM2Q09qfB5cj3GmL9j6x2/pRjYKf0Qm2YpP53rUEfCYyYJ3r8uWPtTGC4+E
vR5jS6wS7W6jEzARMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIg
LEj+/WUkDhfmrCRf4r0cNwQ/2M0wXWJmZSp+2FwsKscCIQDKQ2nEAj+8DkOn2h0o
0fJxQzN9Mn5JgKaYz4cK2vW8mA==
-----END CERTIFICATE-----`

// TestComputeCAHashMatchesDERDigest ensures clone QR hashes match iOS/webapp DER-based certificate hashing.
func TestComputeCAHashMatchesDERDigest(t *testing.T) {
	t.Parallel()
	block, _ := pem.Decode([]byte(testCAPEM))
	require.NotNil(t, block)
	expected := sha256.Sum256(block.Bytes)

	hash, err := ComputeCAHash(testCAPEM)
	require.NoError(t, err)
	assert.Equal(t, hex.EncodeToString(expected[:]), hash)
}

// TestComputeCAHashIgnoresPEMFormatting ensures harmless PEM formatting differences do not change trust matching.
func TestComputeCAHashIgnoresPEMFormatting(t *testing.T) {
	t.Parallel()
	withExtraWhitespace := strings.ReplaceAll(testCAPEM, "\n", "\n\n")

	baseHash, err := ComputeCAHash(testCAPEM)
	require.NoError(t, err)
	variantHash, err := ComputeCAHash(withExtraWhitespace)
	require.NoError(t, err)
	assert.Equal(t, baseHash, variantHash)
}

// TestComputeCAHashRejectsInvalidPEM ensures clone fails early when server discovery returns malformed certificate data.
func TestComputeCAHashRejectsInvalidPEM(t *testing.T) {
	t.Parallel()
	_, err := ComputeCAHash("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----")
	require.Error(t, err)
}
