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

// The slot space is fixed permanently: the hostname is baked into every
// hsproxy certificate and every stored headscale_url, so growing the relay
// fleet must repoint DNS rather than move a deployment to a different slot.
// Changing this number would strand every existing deployment.
func TestTunnelShardSlotsIsFixed(t *testing.T) {
	t.Parallel()

	assert.Equal(t, 64, TunnelShardSlots,
		"the slot space is part of every deployment's hostname and cannot change")
}

// The relay reads the CA fingerprint from the leftmost label of the SNI name,
// as do both clients when verifying a pairing record. The shard component
// therefore has to sit to the right of it, or every one of those readers
// breaks at once.
func TestCATunnelHostKeepsTheCALabelLeftmost(t *testing.T) {
	t.Parallel()

	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)

	host, err := CATunnelHost(testCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)

	assert.Equal(t, label, strings.SplitN(host, ".", 2)[0])
}

// The hostname is what a device dials and what the certificate is issued for,
// so its exact shape is a compatibility surface.
func TestCATunnelHostHasShardLabelThenDomain(t *testing.T) {
	t.Parallel()

	label, err := CADNSLabel(testCAPEM)
	require.NoError(t, err)
	slot, err := CATunnelSlot(testCAPEM)
	require.NoError(t, err)

	host, err := CATunnelHost(testCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)

	expected := label + "." + TunnelShardLabel(slot) + ".tunnel.replycant.com"
	assert.Equal(t, expected, host)
}

// A DNS label caps at 63 octets and a hostname at 253, and the CA label
// already spends 32 characters. Worth pinning because the shard label is the
// second thing competing for that budget.
func TestCATunnelHostFitsInDNS(t *testing.T) {
	t.Parallel()

	host, err := CATunnelHost(testCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)

	assert.LessOrEqual(t, len(host), 253)
	for _, label := range strings.Split(host, ".") {
		assert.LessOrEqual(t, len(label), 63)
	}
}

// The slot has to come from entropy the label does not already spend, or two
// CAs sharing a label prefix would be indistinguishable in both components.
func TestCATunnelSlotComesFromDigestBytesTheLabelDoesNotUse(t *testing.T) {
	t.Parallel()

	block, _ := pem.Decode([]byte(testCAPEM))
	require.NotNil(t, block)
	digest := sha256.Sum256(block.Bytes)

	slot, err := CATunnelSlot(testCAPEM)
	require.NoError(t, err)

	assert.Equal(t, int(digest[caDNSLabelHexChars/2])%TunnelShardSlots, slot)
}

// Every derived slot has to name a shard the fleet can actually serve, or a
// deployment lands on a hostname with no DNS record.
func TestTunnelShardLabelStaysInTheSlotSpace(t *testing.T) {
	t.Parallel()

	for slot := 0; slot < 256; slot++ {
		label := TunnelShardLabel(slot)
		assert.Regexp(t, `^s[0-9]{2}$`, label)
		assert.Less(t, slot%TunnelShardSlots, TunnelShardSlots)
	}
	assert.Equal(t, "s00", TunnelShardLabel(0))
	assert.Equal(t, "s07", TunnelShardLabel(7))
	assert.Equal(t, "s63", TunnelShardLabel(63))
}

// The agent needs no shard knowledge beyond where to dial, and an operator
// should never have to look up which shard their CA landed in.
func TestCATunnelRelayAddrNamesTheShardAndPort(t *testing.T) {
	t.Parallel()

	slot, err := CATunnelSlot(testCAPEM)
	require.NoError(t, err)

	addr, err := CATunnelRelayAddr(testCAPEM, "tunnel.replycant.com", 8444)
	require.NoError(t, err)

	assert.Equal(t, TunnelShardLabel(slot)+".tunnel.replycant.com:8444", addr)
}

// The relay address and the hostname have to name the same shard, or the agent
// registers with one relay while devices are sent to another.
func TestCATunnelRelayAddrAgreesWithTheHostname(t *testing.T) {
	t.Parallel()

	host, err := CATunnelHost(testCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)
	addr, err := CATunnelRelayAddr(testCAPEM, "tunnel.replycant.com", 8444)
	require.NoError(t, err)

	assert.True(t, strings.HasSuffix(host, strings.TrimSuffix(addr, ":8444")),
		"hostname %q must sit under relay %q", host, addr)
}

// Trailing dots and stray whitespace come from templating and environment
// files, and must not produce a hostname with an empty label in it.
func TestCATunnelHostNormalizesTheDomain(t *testing.T) {
	t.Parallel()

	base, err := CATunnelHost(testCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)

	for _, variant := range []string{" tunnel.replycant.com ", "tunnel.replycant.com.", ".tunnel.replycant.com"} {
		host, err := CATunnelHost(testCAPEM, variant)
		require.NoError(t, err)
		assert.Equal(t, base, host, "domain %q", variant)
	}
}

// Malformed input must fail rather than send the deployment to a hostname
// derived from garbage.
func TestCATunnelHostRejectsInvalidPEM(t *testing.T) {
	t.Parallel()

	_, err := CATunnelHost("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----",
		"tunnel.replycant.com")
	require.Error(t, err)
}
