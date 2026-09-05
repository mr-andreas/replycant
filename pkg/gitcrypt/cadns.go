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
	normalized := strings.ReplaceAll(certificatePEM, "-----BEGIN CERTIFICATE-----", "")
	normalized = strings.ReplaceAll(normalized, "-----END CERTIFICATE-----", "")
	normalized = strings.Join(strings.Fields(normalized), "")
	if normalized == "" {
		return "", fmt.Errorf("certificate PEM is empty")
	}
	der, err := base64.StdEncoding.DecodeString(normalized)
	if err != nil {
		return "", fmt.Errorf("certificate PEM is invalid: %w", err)
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
