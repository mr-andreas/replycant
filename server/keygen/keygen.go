package keygen

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// Generates device identity material that can be used for mTLS and repository authorization.
// This keeps CLI onboarding aligned with the iOS flow by producing PEM artifacts and SSH public key text.
func GenerateKeyAndCert(deviceName string, validFor time.Duration) (privateKeyPEM, certPEM []byte, sshPublicKey string, err error) {
	privateKey, err := generateP256PrivateKey()
	if err != nil {
		return nil, nil, "", err
	}

	certDER, err := createSelfSignedCert(deviceName, privateKey, validFor)
	if err != nil {
		return nil, nil, "", err
	}

	privateKeyPEM, err = encodePrivateKeyPEM(privateKey)
	if err != nil {
		return nil, nil, "", err
	}

	certPEM = encodeCertificatePEM(certDER)

	sshPublicKey, err = formatSSHPublicKey(&privateKey.PublicKey, strings.TrimSpace(deviceName))
	if err != nil {
		return nil, nil, "", err
	}

	return privateKeyPEM, certPEM, sshPublicKey, nil
}

// Generates a P-256 private key because the server and iOS clients authenticate with this curve.
func generateP256PrivateKey() (*ecdsa.PrivateKey, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("failed to generate P-256 private key: %w", err)
	}
	return privateKey, nil
}

// Creates a self-signed certificate so a generated key can immediately participate in mTLS.
func createSelfSignedCert(deviceName string, privateKey *ecdsa.PrivateKey, validFor time.Duration) ([]byte, error) {
	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to generate certificate serial number: %w", err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: strings.TrimSpace(deviceName),
		},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(validFor),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create self-signed certificate: %w", err)
	}

	return certDER, nil
}

// Encodes the private key as PEM so operators can persist and reuse the generated identity.
func encodePrivateKeyPEM(privateKey *ecdsa.PrivateKey) ([]byte, error) {
	privateKeyDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal EC private key: %w", err)
	}

	privateKeyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "EC PRIVATE KEY",
		Bytes: privateKeyDER,
	})

	return privateKeyPEM, nil
}

// Encodes certificate DER bytes as PEM to make the credential consumable by standard TLS tooling.
func encodeCertificatePEM(certDER []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})
}

// Formats a P-256 key in SSH wire format so it can be committed to pubkeys/ and parsed by gitd.
func formatSSHPublicKey(publicKey *ecdsa.PublicKey, comment string) (string, error) {
	if publicKey.Curve != elliptic.P256() {
		return "", fmt.Errorf("unsupported curve: expected P-256")
	}

	keyType := "ecdsa-sha2-nistp256"
	curveName := "nistp256"
	point := elliptic.Marshal(elliptic.P256(), publicKey.X, publicKey.Y)
	if len(point) == 0 {
		return "", fmt.Errorf("failed to marshal public key point")
	}

	wire := make([]byte, 0, 4+len(keyType)+4+len(curveName)+4+len(point))
	wire = appendSSHString(wire, []byte(keyType))
	wire = appendSSHString(wire, []byte(curveName))
	wire = appendSSHString(wire, point)

	encoded := base64.StdEncoding.EncodeToString(wire)
	if comment != "" {
		return fmt.Sprintf("%s %s %s", keyType, encoded, comment), nil
	}
	return fmt.Sprintf("%s %s", keyType, encoded), nil
}

// Writes SSH length-prefixed fields to match the parser used by gitd authentication.
func appendSSHString(dst, data []byte) []byte {
	length := make([]byte, 4)
	binary.BigEndian.PutUint32(length, uint32(len(data)))
	dst = append(dst, length...)
	dst = append(dst, data...)
	return dst
}
