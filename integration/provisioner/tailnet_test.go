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
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	err := postPairingRecord(context.Background(), server.Client(), server.URL+"/pair", "sekrit", "age1example")
	if err != nil {
		t.Fatal(err)
	}
	got := string(body)
	if !containsAll(got, `"pairing_secret":"sekrit"`, `"age_pubkey":"age1example"`) {
		t.Fatalf("body = %s", got)
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
