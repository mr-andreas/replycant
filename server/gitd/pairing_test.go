package gitd

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// Stands in for the discovery publisher so these tests cover the HTTP contract
// - who may pair, what a valid request looks like - without a discovery API or
// a headscale behind it.
type recordingPublisher struct {
	mu      sync.Mutex
	calls   int
	secrets []string
	keys    []string
	err     error
}

func (p *recordingPublisher) PublishPairingRecord(_ context.Context, secret, deviceAgePublicKey string) ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	p.secrets = append(p.secrets, secret)
	p.keys = append(p.keys, deviceAgePublicKey)
	if p.err != nil {
		return nil, p.err
	}
	return []byte("sealed-record-bytes"), nil
}

func (p *recordingPublisher) snapshot() (calls int, secrets, keys []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.calls, append([]string(nil), p.secrets...), append([]string(nil), p.keys...)
}

// A well-formed pairing request from an already-trusted device.
func newPairingRequest(t *testing.T, body any) *http.Request {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("encode pairing request: %v", err)
	}
	request := httptest.NewRequest(http.MethodPost, pairingPath, strings.NewReader(string(encoded)))
	request.Header.Set("Content-Type", "application/json")
	return request
}

func validPairingBody() map[string]string {
	return map[string]string{
		"pairing_secret": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ",
		"age_pubkey":     "age1exampleexampleexampleexampleexampleexampleexampleexamplexxxx",
	}
}

// The happy path: an authorized device hands gitd the secret and key it scanned
// off the new device's screen, and gitd publishes a record for it.
func TestPairingRequestPublishesARecord(t *testing.T) {
	publisher := &recordingPublisher{}
	server := &Server{pairingPublisher: publisher}

	recorder := httptest.NewRecorder()
	body := validPairingBody()
	server.handlePairing(recorder, newPairingRequest(t, body))

	if recorder.Code != http.StatusOK {
		t.Fatalf("a valid pairing request must be accepted, got %d: %s",
			recorder.Code, recorder.Body.String())
	}
	// Manual-exposure deployments have no discovery service, so this response
	// body is the only way the record reaches the pairing device.
	if recorder.Body.String() != "sealed-record-bytes" {
		t.Errorf("the sealed record must be returned to the caller, got %q", recorder.Body.String())
	}
	if contentType := recorder.Header().Get("Content-Type"); contentType != "application/octet-stream" {
		t.Errorf("the record is opaque bytes, got content type %q", contentType)
	}

	calls, secrets, keys := publisher.snapshot()
	if calls != 1 {
		t.Fatalf("expected one publish, got %d", calls)
	}
	if secrets[0] != body["pairing_secret"] {
		t.Errorf("the scanned secret must reach the publisher, got %q", secrets[0])
	}
	if keys[0] != body["age_pubkey"] {
		t.Errorf("the scanned device key must reach the publisher, got %q", keys[0])
	}
}

// A deployment with no tailnet cannot mint a credential, so the endpoint
// genuinely does not exist there. Answering 404 rather than 500 keeps LAN-only
// deployments from looking broken.
func TestPairingIsNotOfferedWithoutAPublisher(t *testing.T) {
	server := &Server{}

	recorder := httptest.NewRecorder()
	server.handlePairing(recorder, newPairingRequest(t, validPairingBody()))

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("pairing must not be offered without a publisher, got %d", recorder.Code)
	}
}

// Both fields are required to produce a record anyone can open, so an
// incomplete request is refused before a credential is minted for it.
func TestIncompletePairingRequestsAreRejected(t *testing.T) {
	for _, testCase := range []struct {
		name string
		body map[string]string
	}{
		{"no secret", map[string]string{"age_pubkey": "age1example"}},
		{"no device key", map[string]string{"pairing_secret": "c2VjcmV0"}},
		{"neither", map[string]string{}},
		{"blank secret", map[string]string{"pairing_secret": "  ", "age_pubkey": "age1example"}},
		{"blank device key", map[string]string{"pairing_secret": "c2VjcmV0", "age_pubkey": " "}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			publisher := &recordingPublisher{}
			server := &Server{pairingPublisher: publisher}

			recorder := httptest.NewRecorder()
			server.handlePairing(recorder, newPairingRequest(t, testCase.body))

			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("an incomplete request must be refused, got %d", recorder.Code)
			}
			if calls, _, _ := publisher.snapshot(); calls != 0 {
				t.Errorf("nothing should be published for an invalid request, got %d publishes", calls)
			}
		})
	}
}

// A body that is not JSON at all is a client bug, not a server error.
func TestMalformedPairingBodyIsRejected(t *testing.T) {
	publisher := &recordingPublisher{}
	server := &Server{pairingPublisher: publisher}

	request := httptest.NewRequest(http.MethodPost, pairingPath, strings.NewReader("{not json"))
	recorder := httptest.NewRecorder()
	server.handlePairing(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("a malformed body must be refused, got %d", recorder.Code)
	}
	if calls, _, _ := publisher.snapshot(); calls != 0 {
		t.Errorf("nothing should be published, got %d publishes", calls)
	}
}

// Publishing is a state change, so it must not be reachable by a GET that a
// browser or a link preview could trigger.
func TestOnlyPostCanPair(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodHead} {
		t.Run(method, func(t *testing.T) {
			publisher := &recordingPublisher{}
			server := &Server{pairingPublisher: publisher}

			request := httptest.NewRequest(method, pairingPath, nil)
			recorder := httptest.NewRecorder()
			server.handlePairing(recorder, request)

			if recorder.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s must not pair, got %d", method, recorder.Code)
			}
			if calls, _, _ := publisher.snapshot(); calls != 0 {
				t.Errorf("nothing should be published, got %d publishes", calls)
			}
		})
	}
}

// A failure downstream - headscale unreachable, discovery rejecting the record
// - must be reported so the pairing UI can say pairing failed instead of
// waiting for a record that will never appear.
func TestPublishFailureIsReported(t *testing.T) {
	publisher := &recordingPublisher{err: errors.New("headscale is down")}
	server := &Server{pairingPublisher: publisher}

	recorder := httptest.NewRecorder()
	server.handlePairing(recorder, newPairingRequest(t, validPairingBody()))

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("a downstream failure must be reported, got %d", recorder.Code)
	}
}

// The response must not echo the failure verbatim: it can contain internal
// hostnames and headscale detail that a client has no business seeing.
func TestPublishFailureDetailIsNotLeaked(t *testing.T) {
	publisher := &recordingPublisher{err: errors.New("dial tcp 10.1.2.3:8080: connection refused")}
	server := &Server{pairingPublisher: publisher}

	recorder := httptest.NewRecorder()
	server.handlePairing(recorder, newPairingRequest(t, validPairingBody()))

	if strings.Contains(recorder.Body.String(), "10.1.2.3") {
		t.Errorf("internal detail must not reach the client, got %q", recorder.Body.String())
	}
}

// An unbounded body would let an authenticated but misbehaving client exhaust
// gitd's memory through an endpoint that exists to read two short strings.
func TestOversizedPairingBodyIsRejected(t *testing.T) {
	publisher := &recordingPublisher{}
	server := &Server{pairingPublisher: publisher}

	oversized := strings.Repeat("a", maxPairingRequestBytes+1024)
	request := httptest.NewRequest(http.MethodPost, pairingPath,
		strings.NewReader(`{"pairing_secret":"`+oversized+`"}`))
	recorder := httptest.NewRecorder()
	server.handlePairing(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("an oversized body must be refused, got %d", recorder.Code)
	}
	if calls, _, _ := publisher.snapshot(); calls != 0 {
		t.Errorf("nothing should be published, got %d publishes", calls)
	}
}
