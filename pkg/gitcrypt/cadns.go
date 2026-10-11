package gitcrypt

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

// Number of hex characters taken from the CA's SHA-256 digest to form a DNS
// label. A DNS label may not exceed 63 octets, so the full 64-character digest
// does not fit. 32 hex characters keep 128 bits, which is far more than an
// attacker could grind through to obtain a CA that collides with someone
// else's tunnel hostname.
const caDNSLabelHexChars = 32

// Derives the DNS label that identifies a deployment's CA in tunnel hostnames
// such as `<label>.tunnel.replycant.com`.
//
// Putting the CA fingerprint in the hostname is what lets the reverse tunnel
// verify a registration without holding any shared secret or knowing the CA in
// advance: it hashes the presented chain root and checks it against the label
// being claimed. Clients derive the same label from the CA they already trust.
func CADNSLabel(certificatePEM string) (string, error) {
	der, err := caDER(certificatePEM)
	if err != nil {
		return "", err
	}
	return CADNSLabelFromDER(der), nil
}

// Derives the tunnel DNS label straight from certificate DER.
//
// The tunnel service only ever sees a TLS chain, never PEM, so it needs this
// form. Both entry points share one implementation so the label a deployment
// registers can never disagree with the label its devices dial.
func CADNSLabelFromDER(der []byte) string {
	digest := sha256.Sum256(der)
	return strings.ToLower(hex.EncodeToString(digest[:])[:caDNSLabelHexChars])
}

// How many shards the tunnel hostname space is divided into.
//
// Fixed, permanently. Registrations live in one relay process's memory, so the
// fleet has to be sharded by hostname rather than by shared state, and the
// hostname is baked into every hsproxy certificate and every stored
// headscale_url. Growing the fleet must therefore repoint DNS for some slots
// rather than change any deployment's hostname: no certificate reissue, no
// stranded device. 64 is well above any plausible relay count, and an unused
// slot costs one DNS record.
const TunnelShardSlots = 64

// Byte of the CA digest the shard slot is taken from.
//
// Immediately past the 16 bytes the DNS label consumes, so the slot carries
// entropy the label does not already spend. Deriving it from the same digest is
// what lets a device, the compose stack, and the relay each compute the
// hostname from the CA alone.
const caShardDigestByte = caDNSLabelHexChars / 2

// Derives the shard slot for a CA from its certificate DER.
func CATunnelSlotFromDER(der []byte) int {
	digest := sha256.Sum256(der)
	return int(digest[caShardDigestByte]) % TunnelShardSlots
}

// Derives the shard slot for a CA from its certificate PEM.
func CATunnelSlot(certificatePEM string) (int, error) {
	der, err := caDER(certificatePEM)
	if err != nil {
		return 0, err
	}
	return CATunnelSlotFromDER(der), nil
}

// The DNS label naming one shard, as it appears in a tunnel hostname.
//
// Zero-padded so the label sorts the way the slot number does, which matters
// only for humans reading DNS and template output, but costs nothing.
func TunnelShardLabel(slot int) string {
	return fmt.Sprintf("s%02d", slot%TunnelShardSlots)
}

// Derives a deployment's full tunnel hostname from its CA and the tunnel
// domain.
//
// The shard label sits between the CA label and the domain, so the leftmost
// label is still the CA fingerprint. Every reader of that fingerprint - the
// relay's SNI check, and both clients' pairing-record verification - takes only
// the leftmost label, so inserting a shard component changes none of them.
func CATunnelHostFromDER(der []byte, tunnelDomain string) string {
	domain := strings.Trim(strings.TrimSpace(tunnelDomain), ".")
	return fmt.Sprintf("%s.%s.%s",
		CADNSLabelFromDER(der), TunnelShardLabel(CATunnelSlotFromDER(der)), domain)
}

// Derives a deployment's tunnel hostname from its CA certificate PEM.
func CATunnelHost(certificatePEM, tunnelDomain string) (string, error) {
	der, err := caDER(certificatePEM)
	if err != nil {
		return "", err
	}
	return CATunnelHostFromDER(der, tunnelDomain), nil
}

// Where the tunnel agent for a CA should register.
//
// Derived rather than configured so an operator never has to know which shard
// their deployment belongs to; the override exists for self-hosted relays.
func CATunnelRelayAddr(certificatePEM, tunnelDomain string, port int) (string, error) {
	der, err := caDER(certificatePEM)
	if err != nil {
		return "", err
	}
	domain := strings.Trim(strings.TrimSpace(tunnelDomain), ".")
	return fmt.Sprintf("%s.%s:%d",
		TunnelShardLabel(CATunnelSlotFromDER(der)), domain, port), nil
}

// Extracts DER from a certificate PEM, shared by every derivation above so a
// formatting quirk cannot make the hostname and the relay address disagree.
func caDER(certificatePEM string) ([]byte, error) {
	normalized := strings.ReplaceAll(certificatePEM, "-----BEGIN CERTIFICATE-----", "")
	normalized = strings.ReplaceAll(normalized, "-----END CERTIFICATE-----", "")
	normalized = strings.Join(strings.Fields(normalized), "")
	if normalized == "" {
		return nil, fmt.Errorf("certificate PEM is empty")
	}
	der, err := base64.StdEncoding.DecodeString(normalized)
	if err != nil {
		return nil, fmt.Errorf("certificate PEM is invalid: %w", err)
	}
	return der, nil
}
