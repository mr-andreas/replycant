package tunnelagent

import (
	"encoding/pem"
	"fmt"
)

// Extracts the first certificate's DER bytes from a PEM file.
//
// The relay derives the tunnel subdomain from the exact DER of the CA, so this
// has to return the certificate itself and not, for example, silently accept a
// key or a chain in an unexpected order. Getting the wrong bytes here would
// produce a label no device ever dials, which is a confusing failure to debug.
func firstCertificateDER(pemBytes []byte) ([]byte, error) {
	rest := pemBytes
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return nil, fmt.Errorf("no CERTIFICATE block found in PEM input")
		}
		if block.Type == "CERTIFICATE" {
			return block.Bytes, nil
		}
	}
}
