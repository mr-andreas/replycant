package pairing

import (
	"context"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"crypto/ecdsa"
	"crypto/elliptic"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	pairingblob "github.com/mr-andreas/replycant/pkg/pairing"
)

// Records what the discovery API received so tests can assert on the published
// record without needing the hosted service.
type fakeDiscovery struct {
	mu      sync.Mutex
	puts    int
	lastURL string
	lastCT  string
	lastRaw []byte
	status  int
	server  *httptest.Server
}

func newFakeDiscovery(t *testing.T) *fakeDiscovery {
	t.Helper()
	fake := &fakeDiscovery{status: http.StatusNoContent}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		fake.mu.Lock()
		fake.puts++
		fake.lastURL = r.Host + r.URL.Path
		fake.lastCT = r.Header.Get("Content-Type")
		fake.lastRaw = body
		status := fake.status
		fake.mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

// The publisher addresses records at {slot}.{discovery host}, which is a real
// DNS name in production but unresolvable when the host is a test server's
// loopback address. This client sends every request to the fake regardless of
// hostname, so the Host header still carries the slot and can be asserted on.
func (f *fakeDiscovery) client() *http.Client {
	address := strings.TrimPrefix(f.server.URL, "http://")
	return &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, address)
			},
		},
	}
}

func (f *fakeDiscovery) snapshot() (puts int, url, contentType string, raw []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.puts, f.lastURL, f.lastCT, f.lastRaw
}

func (f *fakeDiscovery) setStatus(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

// Returns a fixed key, standing in for headscale.
type fakeMinter struct {
	key       string
	err       error
	requested []time.Duration
	mu        sync.Mutex
}

func (m *fakeMinter) MintPreauthKey(_ context.Context, validFor time.Duration) (string, error) {
	m.mu.Lock()
	m.requested = append(m.requested, validFor)
	m.mu.Unlock()
	if m.err != nil {
		return "", m.err
	}
	return m.key, nil
}

func (m *fakeMinter) ttls() []time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]time.Duration(nil), m.requested...)
}

// Writes a CA certificate to disk, since the publisher reads the CA it
// distributes from the same file the rest of the stack uses.
func writeTestCA(t *testing.T) (path string, pemBytes []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "replycant test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	pemBytes = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})

	path = filepath.Join(t.TempDir(), "ca.crt")
	if err := os.WriteFile(path, pemBytes, 0o644); err != nil {
		t.Fatalf("write CA cert: %v", err)
	}
	return path, pemBytes
}

// A device identity, as the pairing QR would carry it.
func newTestDevice(t *testing.T) gitcrypt.Identity {
	t.Helper()
	identity, _, _, err := gitcrypt.CreateIdentityWithMTLS("test-device")
	if err != nil {
		t.Fatalf("create device identity: %v", err)
	}
	return identity
}

func newTestPublisher(t *testing.T, fake *fakeDiscovery, minter Minter) (*Publisher, []byte) {
	t.Helper()
	caPath, caPEM := writeTestCA(t)
	publisher, err := NewPublisher(Config{
		Minter:          minter,
		CACertPath:      caPath,
		HeadscaleURL:    "https://abc.tunnel.replycant.com",
		GitdTailnetName: "gitd.replycant.internal",
		BaseDomain:      "replycant.internal",
		DiscoveryURL:    fake.server.URL,
		HTTPClient:      fake.client(),
	})
	if err != nil {
		t.Fatalf("a complete config must build a publisher: %v", err)
	}
	return publisher, caPEM
}

// The whole point of the writer side: what gitd publishes must be openable by
// the device that generated the secret, and must carry everything that device
// needs to join. This is the test that would catch a format drift between the
// writer and the reader.
func TestPublishedRecordOpensOnTheDevice(t *testing.T) {
	fake := newFakeDiscovery(t)
	minter := &fakeMinter{key: "hskey-auth-forthisdevice"}
	publisher, caPEM := newTestPublisher(t, fake, minter)
	device := newTestDevice(t)

	secret, err := pairingblob.NewSecret()
	if err != nil {
		t.Fatalf("generate secret: %v", err)
	}

	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}

	_, _, _, raw := fake.snapshot()
	payload, err := pairingblob.Open(secret, device.AgePrivateKeyBase64, raw)
	if err != nil {
		t.Fatalf("the device must be able to open what gitd published: %v", err)
	}

	if payload.PreauthKey != "hskey-auth-forthisdevice" {
		t.Errorf("the minted key must reach the device, got %q", payload.PreauthKey)
	}
	if payload.HeadscaleURL != "https://abc.tunnel.replycant.com" {
		t.Errorf("unexpected headscale URL %q", payload.HeadscaleURL)
	}
	if strings.TrimSpace(payload.CAPEM) != strings.TrimSpace(string(caPEM)) {
		t.Error("the device must receive the deployment's real CA")
	}
	if payload.GitdTailnetName != "gitd.replycant.internal" {
		t.Errorf("unexpected gitd name %q", payload.GitdTailnetName)
	}
	if payload.BaseDomain != "replycant.internal" {
		t.Errorf("unexpected base domain %q", payload.BaseDomain)
	}
}

// The record must land on the slot the device is polling. Deriving it from the
// secret on both sides means it never has to be transmitted, but it also means
// a derivation mismatch would present as a pairing that silently never
// completes.
func TestRecordIsPublishedToTheSecretsSlot(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})
	device := newTestDevice(t)

	secret, err := pairingblob.NewSecret()
	if err != nil {
		t.Fatalf("generate secret: %v", err)
	}
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}

	_, requestURL, _, _ := fake.snapshot()
	if !strings.HasPrefix(requestURL, secret.Slot()+".") {
		t.Errorf("the record must be addressed to the secret's slot %q, went to %q",
			secret.Slot(), requestURL)
	}
}

// A record that is readable by the discovery service, or by anyone who can see
// the request, would defeat the design. The stored bytes must not contain the
// pre-auth key or the CA in the clear.
func TestPublishedRecordIsOpaque(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, caPEM := newTestPublisher(t, fake, &fakeMinter{key: "hskey-auth-secretvalue"})
	device := newTestDevice(t)

	secret, err := pairingblob.NewSecret()
	if err != nil {
		t.Fatalf("generate secret: %v", err)
	}
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}

	_, _, _, raw := fake.snapshot()
	for _, secretValue := range []string{
		"hskey-auth-secretvalue",
		"replycant.internal",
		"tunnel.replycant.com",
		string(caPEM),
	} {
		if strings.Contains(string(raw), secretValue) {
			t.Errorf("the stored record must not leak %q in the clear", secretValue)
		}
	}
}

// Pre-auth keys are the one credential in the record that grants tailnet
// access. A long TTL would leave a usable key sitting in a discovery record or
// a photographed QR long after pairing was abandoned.
func TestMintedKeyIsShortLived(t *testing.T) {
	fake := newFakeDiscovery(t)
	minter := &fakeMinter{key: "k"}
	publisher, _ := newTestPublisher(t, fake, minter)
	device := newTestDevice(t)

	secret, _ := pairingblob.NewSecret()
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}

	ttls := minter.ttls()
	if len(ttls) != 1 {
		t.Fatalf("exactly one key should be minted per pairing, got %d", len(ttls))
	}
	if ttls[0] > time.Hour {
		t.Errorf("the pre-auth key TTL should be short, got %v", ttls[0])
	}
}

// A key that was minted but never delivered is a small leak: it stays valid in
// headscale with nobody holding it. More importantly, the operator needs to
// know pairing failed rather than seeing it hang.
func TestDiscoveryFailureIsReported(t *testing.T) {
	fake := newFakeDiscovery(t)
	fake.setStatus(http.StatusInternalServerError)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})
	device := newTestDevice(t)

	secret, _ := pairingblob.NewSecret()
	_, err := publisher.Publish(context.Background(), secret, device.AgePublicKey)
	if err == nil {
		t.Fatal("publishing must fail when the discovery API rejects the record")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("the error should carry the status, got %v", err)
	}
}

// If headscale cannot mint a key there is nothing worth publishing, so the
// record must not be written at all. Publishing a record without a usable key
// would consume the device's single-use slot read for nothing.
func TestNothingIsPublishedWhenMintingFails(t *testing.T) {
	fake := newFakeDiscovery(t)
	minter := &fakeMinter{err: errors.New("headscale is down")}
	publisher, _ := newTestPublisher(t, fake, minter)
	device := newTestDevice(t)

	secret, _ := pairingblob.NewSecret()
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err == nil {
		t.Fatal("publishing must fail when no key can be minted")
	}

	if puts, _, _, _ := fake.snapshot(); puts != 0 {
		t.Errorf("no record should be written when minting failed, got %d writes", puts)
	}
}

// The device's age public key comes off a scanned QR code, so a garbled or
// hostile value has to be rejected rather than producing a record nobody can
// open.
func TestMalformedDeviceKeyIsRejected(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})

	secret, _ := pairingblob.NewSecret()
	for _, name := range []string{"", "not-an-age-key", "age1invalid"} {
		t.Run(name, func(t *testing.T) {
			if _, err := publisher.Publish(context.Background(), secret, name); err == nil {
				t.Fatal("a malformed device key must be rejected")
			}
		})
	}
	if puts, _, _, _ := fake.snapshot(); puts != 0 {
		t.Errorf("nothing should be published for a malformed key, got %d writes", puts)
	}
}

// The discovery API distinguishes records by content type, and a mismatch is
// rejected there. Asserting it here keeps the failure local to this package.
func TestRecordIsSentAsOpaqueBytes(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})
	device := newTestDevice(t)

	secret, _ := pairingblob.NewSecret()
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}
	if _, _, contentType, _ := fake.snapshot(); contentType != "application/octet-stream" {
		t.Errorf("records are opaque bytes, got content type %q", contentType)
	}
}

// The CA is read at publish time rather than at construction so a rotated CA
// reaches new devices without restarting gitd.
func TestCAIsReadAtPublishTime(t *testing.T) {
	fake := newFakeDiscovery(t)
	caPath, _ := writeTestCA(t)
	publisher, err := NewPublisher(Config{
		Minter:          &fakeMinter{key: "k"},
		CACertPath:      caPath,
		HeadscaleURL:    "https://abc.tunnel.replycant.com",
		GitdTailnetName: "gitd.replycant.internal",
		BaseDomain:      "replycant.internal",
		DiscoveryURL:    fake.server.URL,
		HTTPClient:      fake.client(),
	})
	if err != nil {
		t.Fatalf("build publisher: %v", err)
	}

	_, rotatedPEM := writeTestCA(t)
	if err := os.WriteFile(caPath, rotatedPEM, 0o644); err != nil {
		t.Fatalf("rotate CA: %v", err)
	}

	device := newTestDevice(t)
	secret, _ := pairingblob.NewSecret()
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err != nil {
		t.Fatalf("publishing must succeed: %v", err)
	}

	_, _, _, raw := fake.snapshot()
	payload, err := pairingblob.Open(secret, device.AgePrivateKeyBase64, raw)
	if err != nil {
		t.Fatalf("open published record: %v", err)
	}
	if strings.TrimSpace(payload.CAPEM) != strings.TrimSpace(string(rotatedPEM)) {
		t.Error("a rotated CA must reach newly paired devices")
	}
}

// A missing CA file means the stack is not initialised. Failing at publish
// time with a clear error beats sealing an empty CA into a record.
func TestMissingCAIsReported(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, err := NewPublisher(Config{
		Minter:          &fakeMinter{key: "k"},
		CACertPath:      filepath.Join(t.TempDir(), "absent.crt"),
		HeadscaleURL:    "https://abc.tunnel.replycant.com",
		GitdTailnetName: "gitd.replycant.internal",
		BaseDomain:      "replycant.internal",
		DiscoveryURL:    fake.server.URL,
		HTTPClient:      fake.client(),
	})
	if err != nil {
		t.Fatalf("a missing file should not fail construction: %v", err)
	}

	device := newTestDevice(t)
	secret, _ := pairingblob.NewSecret()
	if _, err := publisher.Publish(context.Background(), secret, device.AgePublicKey); err == nil {
		t.Fatal("publishing must fail when the CA cannot be read")
	}
}

// Every field is needed to produce a usable record, so an incomplete config is
// caught when gitd starts rather than when someone tries to pair.
func TestNewPublisherRejectsIncompleteConfig(t *testing.T) {
	caPath, _ := writeTestCA(t)
	complete := Config{
		Minter:          &fakeMinter{key: "k"},
		CACertPath:      caPath,
		HeadscaleURL:    "https://abc.tunnel.replycant.com",
		GitdTailnetName: "gitd.replycant.internal",
		BaseDomain:      "replycant.internal",
		DiscoveryURL:    "https://discovery.replycant.com",
	}

	for _, testCase := range []struct {
		name   string
		mutate func(*Config)
	}{
		{"no minter", func(c *Config) { c.Minter = nil }},
		{"no CA path", func(c *Config) { c.CACertPath = "" }},
		{"no headscale URL", func(c *Config) { c.HeadscaleURL = "" }},
		{"no gitd name", func(c *Config) { c.GitdTailnetName = "" }},
		{"no base domain", func(c *Config) { c.BaseDomain = "" }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			config := complete
			testCase.mutate(&config)
			if _, err := NewPublisher(config); err == nil {
				t.Fatal("an incomplete config must be rejected")
			}
		})
	}
}

// gitd's endpoint hands over whatever was scanned, so the string form has to
// produce the same record as the parsed form.
func TestPublishFromScannedValues(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "hskey-auth-scanned"})
	device := newTestDevice(t)

	secret, err := pairingblob.NewSecret()
	if err != nil {
		t.Fatalf("generate secret: %v", err)
	}

	if _, err := publisher.PublishPairingRecord(context.Background(), secret.String(), device.AgePublicKey); err != nil {
		t.Fatalf("publishing from scanned values must succeed: %v", err)
	}

	_, _, _, raw := fake.snapshot()
	payload, err := pairingblob.Open(secret, device.AgePrivateKeyBase64, raw)
	if err != nil {
		t.Fatalf("the device must be able to open the record: %v", err)
	}
	if payload.PreauthKey != "hskey-auth-scanned" {
		t.Errorf("unexpected key %q", payload.PreauthKey)
	}
}

// A secret that did not survive the scan would otherwise produce a record on a
// slot nobody is polling, which looks like a pairing that just never finishes.
func TestUnparseableScannedSecretIsRejected(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})
	device := newTestDevice(t)

	for _, name := range []string{"", "!!!not base64!!!", "dG9vLXNob3J0"} {
		t.Run(name, func(t *testing.T) {
			if _, err := publisher.PublishPairingRecord(context.Background(), name, device.AgePublicKey); err == nil {
				t.Fatal("an unusable secret must be rejected")
			}
		})
	}
	if puts, _, _, _ := fake.snapshot(); puts != 0 {
		t.Errorf("nothing should be published, got %d writes", puts)
	}
}

// Two devices pairing at once must each get their own record and their own
// key. Run with -race, this also covers the publisher being shared across
// gitd's request goroutines.
func TestConcurrentPublishesAreIndependent(t *testing.T) {
	fake := newFakeDiscovery(t)
	publisher, _ := newTestPublisher(t, fake, &fakeMinter{key: "k"})

	const devices = 6
	errs := make(chan error, devices)
	for range devices {
		go func() {
			device := newTestDevice(t)
			secret, err := pairingblob.NewSecret()
			if err != nil {
				errs <- err
				return
			}
			_, publishErr := publisher.Publish(context.Background(), secret, device.AgePublicKey)
			errs <- publishErr
		}()
	}
	for range devices {
		if err := <-errs; err != nil {
			t.Errorf("concurrent publishing must succeed: %v", err)
		}
	}
	if puts, _, _, _ := fake.snapshot(); puts != devices {
		t.Errorf("each device needs its own record, got %d", puts)
	}
}
