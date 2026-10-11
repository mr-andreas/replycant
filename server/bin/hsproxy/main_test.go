package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alecthomas/kong"
)

// docker-compose.yaml and the integration harness start hsproxy with these
// exact flags. Kong derives flag names from field names, and an acronym like
// APIURL silently becomes `apiurl`, so a rename here would only show up as
// hsproxy refusing to start in a deployment.
func TestParsesTheHeadscaleAPIFlagsComposeUses(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli)
	if err != nil {
		t.Fatalf("kong.New() error = %v", err)
	}
	_, err = parser.Parse([]string{
		"--repo=/data/repo",
		"--upstream=headscale:8080",
		"--cert=/data/hsproxy.crt",
		"--key=/data/hsproxy.key",
		"--ca=/data/ca.crt",
		"--headscale-api-url=http://headscale:8080",
		"--headscale-api-key-file=/data/tailnet/headscale.apikey",
	})
	if err != nil {
		t.Fatalf("hsproxy must accept the flags compose passes: %v", err)
	}
	if cli.HeadscaleAPIURL != "http://headscale:8080" {
		t.Errorf("expected the API URL to be parsed, got %q", cli.HeadscaleAPIURL)
	}
	if cli.HeadscaleAPIKeyFile != "/data/tailnet/headscale.apikey" {
		t.Errorf("expected the API key file to be parsed, got %q", cli.HeadscaleAPIKeyFile)
	}
	if cli.CA != "/data/ca.crt" {
		t.Errorf("expected the CA path to be parsed, got %q", cli.CA)
	}
}

// A phone restoring from a recovery key knows only the CA's hash, and hsproxy
// is the one server it can reach. Sending the CA after the leaf in the TLS
// chain is how the phone obtains the CA it then checks against that hash.
func TestServerChainCarriesTheCA(t *testing.T) {
	dir := t.TempDir()
	caKey, caCert := writeTestCA(t, dir)
	writeTestLeaf(t, dir, caKey, caCert)

	served, err := loadServerCertificate(
		filepath.Join(dir, "hsproxy.crt"),
		filepath.Join(dir, "hsproxy.key"),
		filepath.Join(dir, "ca.crt"),
	)
	if err != nil {
		t.Fatalf("load the server certificate: %v", err)
	}
	if len(served.Certificate) != 2 || !bytes.Equal(served.Certificate[1], caCert.Raw) {
		t.Fatalf("expected the chain to be the leaf followed by the CA, got %d certificates",
			len(served.Certificate))
	}
}

// Serving a CA that did not sign the leaf would hand recovering phones a
// certificate whose hash matches but which cannot verify hsproxy, failing
// every recovery in a way that looks like a network fault.
func TestServerChainRejectsACAThatDidNotSignTheLeaf(t *testing.T) {
	dir := t.TempDir()
	caKey, caCert := writeTestCA(t, dir)
	writeTestLeaf(t, dir, caKey, caCert)
	otherDir := t.TempDir()
	writeTestCA(t, otherDir)

	_, err := loadServerCertificate(
		filepath.Join(dir, "hsproxy.crt"),
		filepath.Join(dir, "hsproxy.key"),
		filepath.Join(otherDir, "ca.crt"),
	)
	if err == nil {
		t.Fatal("a CA that did not sign the leaf must be rejected")
	}
}

func writeTestCA(t *testing.T, dir string) (*ecdsa.PrivateKey, *x509.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	writePEM(t, filepath.Join(dir, "ca.crt"), "CERTIFICATE", der)
	return key, cert
}

func writeTestLeaf(t *testing.T, dir string, caKey *ecdsa.PrivateKey, caCert *x509.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "hsproxy.example.com"},
		DNSNames:     []string{"hsproxy.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	writePEM(t, filepath.Join(dir, "hsproxy.crt"), "CERTIFICATE", der)
	writePEM(t, filepath.Join(dir, "hsproxy.key"), "EC PRIVATE KEY", keyDER)
}

func writePEM(t *testing.T, path, blockType string, der []byte) {
	t.Helper()
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
}
