package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFetchQRPayloadReadsPairingFields(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/payload.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"pairing_secret":"sekrit","age_pubkey":"age1example","pubkey":"ssh"}`))
	}))
	defer server.Close()

	payload, err := fetchQRPayload(context.Background(), server.URL+"/payload.json")
	if err != nil {
		t.Fatal(err)
	}
	if payload.PairingSecret != "sekrit" || payload.AgePublicKey != "age1example" {
		t.Fatalf("payload = %+v", payload)
	}
}

func TestPostPairingRecordSendsTheQRFields(t *testing.T) {
	var body []byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/pair" {
			http.NotFound(w, r)
			return
		}
		var err error
		body, err = io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	err := postPairingRecord(context.Background(), server.Client(), server.URL+"/pair", "sekrit")
	if err != nil {
		t.Fatal(err)
	}
	got := string(body)
	if !containsAll(got, `"pairing_secret":"sekrit"`) || containsAll(got, `"age_pubkey"`) {
		t.Fatalf("body = %s", got)
	}
}

// A host-side harness drives approval through the control service rather
// than a loopback QR page, so it hands over only the secret. The age key
// still has to be the new device's: it is committed to pubkeys/ so later
// epoch wraps include this device.
func TestPairingSecretFlagPairsTheNewIdentity(t *testing.T) {
	cfg := provisionerConfig{pairingSecret: "sekrit"}
	payload, pairing, err := resolvePairing(context.Background(), cfg, "age1newdevice")
	if err != nil {
		t.Fatal(err)
	}
	if !pairing || payload.PairingSecret != "sekrit" || payload.AgePublicKey != "age1newdevice" {
		t.Fatalf("payload = %+v, pairing = %v", payload, pairing)
	}
}

func TestProvisioningWithoutAPairingSourceOnlyCommitsTheKey(t *testing.T) {
	_, pairing, err := resolvePairing(context.Background(), provisionerConfig{}, "age1newdevice")
	if err != nil || pairing {
		t.Fatalf("pairing = %v, err = %v", pairing, err)
	}
}

func TestPairingSourcesAreExclusive(t *testing.T) {
	cfg := provisionerConfig{pairingSecret: "sekrit", qrURL: "http://127.0.0.1:1/payload.json"}
	if _, _, err := resolvePairing(context.Background(), cfg, "age1newdevice"); err == nil {
		t.Fatal("expected an error when both --qr-url and --pairing-secret are set")
	}
}

func containsAll(s string, parts ...string) bool {
	for _, part := range parts {
		if !contains(s, part) {
			return false
		}
	}
	return true
}

func contains(s, part string) bool {
	return len(s) >= len(part) && (s == part || len(part) == 0 || (func() bool {
		for i := 0; i+len(part) <= len(s); i++ {
			if s[i:i+len(part)] == part {
				return true
			}
		}
		return false
	})())
}
