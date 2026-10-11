package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// Host-side suites have no other way to learn the CA the container minted at
// startup, and they need it to pin hsproxy when joining the tailnet.
func TestCAServesTheHarnessCertificate(t *testing.T) {
	caPath := filepath.Join(t.TempDir(), "ca.crt")
	const pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
	if err := os.WriteFile(caPath, []byte(pem), 0o600); err != nil {
		t.Fatal(err)
	}
	server := &controlServer{caPath: caPath}

	rec := httptest.NewRecorder()
	server.handleCA(rec, httptest.NewRequest(http.MethodGet, "/ca", nil))

	if rec.Code != http.StatusOK || rec.Body.String() != pem {
		t.Fatalf("GET /ca = %d %q", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "application/x-pem-file") {
		t.Errorf("Content-Type = %q", got)
	}
}

// Committing the key is enough for a device that mints its own tailnet key.
// A device that is still polling discovery also needs gitd to publish its
// record, which is what an authorizing device does after the commit.
func TestProvisionWithAPairingSecretAlsoApprovesThePairing(t *testing.T) {
	plain := provisionerArgs(provisionRequest{}, "/tmp/new.json")
	if slices.ContainsFunc(plain, func(arg string) bool { return strings.HasPrefix(arg, "--pair") }) {
		t.Fatalf("plain provisioning must not pair: %v", plain)
	}

	paired := provisionerArgs(provisionRequest{PairingSecret: "sekrit"}, "/tmp/new.json")
	for _, want := range []string{
		"--pairing-secret=sekrit",
		"--ca-file=" + caPath,
		"--headscale-url=" + headscaleURL,
		"--pair-url=" + pairURL,
	} {
		if !slices.Contains(paired, want) {
			t.Errorf("missing %s in %v", want, paired)
		}
	}
}
