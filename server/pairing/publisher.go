// Package pairing is gitd's writer side of the discovery handshake.
//
// A device that has never paired knows nothing about the deployment: not the
// CA, and not where headscale is. Both have to arrive in one record it can
// trust, published by something that already holds the deployment's CA. That
// is gitd, which is why this lives here rather than in the hosted service.
// No tailnet credential travels in the record: once its key is in pubkeys/,
// the device mints its own from hsproxy.
//
// The record is published to a slot derived from the pairing secret shown in
// the QR code, so the discovery API never learns who a record is for and the
// slot never has to be transmitted. See pkg/pairing for why one AEAD under
// that secret is the whole protection.
package pairing

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	pairingblob "github.com/mr-andreas/replycant/pkg/pairing"
)

// Re-exported so gitd and its handlers need only this package to publish a
// record, while the record format itself stays in pkg/pairing where clients
// can share it.
type (
	Secret  = pairingblob.Secret
	Payload = pairingblob.Payload
)

// What the discovery API requires records to be labelled as. It stores them as
// opaque bytes and rejects anything claiming to be structured, because it must
// never be in a position to read one.
const recordContentType = "application/octet-stream"

// How long to wait on the discovery API. Someone is watching a spinner.
const publishTimeout = 15 * time.Second

// How much of a failed response to quote back when reporting an error.
const maxErrorBodyBytes = 512

// Everything gitd needs to describe its own deployment to a new device.
type Config struct {
	// Read at publish time rather than cached, so rotating the CA reaches
	// newly paired devices without restarting gitd.
	CACertPath string

	// Where the device should point its tailnet client: the tunnel hostname
	// derived from the deployment CA.
	HeadscaleURL string

	// Base URL of the discovery API. The slot is prepended as a subdomain, so
	// this is the parent domain rather than a full record URL. Required: the
	// discovery API is the only way a pairing record reaches a new device.
	DiscoveryURL string

	// Overridable for tests; production uses a client with publishTimeout.
	HTTPClient *http.Client
}

// Publishes pairing records for one deployment. Safe for concurrent use, since
// gitd serves pairing requests from its ordinary request goroutines.
type Publisher struct {
	config     Config
	httpClient *http.Client

	// Split from the configured URL once at construction so the per-publish
	// path only has to insert the slot.
	discoveryScheme string
	discoveryHost   string
}

// Validates the deployment description so a misconfiguration surfaces when
// gitd starts instead of when a user is standing there with a QR code open.
func NewPublisher(config Config) (*Publisher, error) {
	missing := make([]string, 0, 3)
	if strings.TrimSpace(config.CACertPath) == "" {
		missing = append(missing, "CA certificate path")
	}
	if strings.TrimSpace(config.HeadscaleURL) == "" {
		missing = append(missing, "headscale URL")
	}
	if strings.TrimSpace(config.DiscoveryURL) == "" {
		missing = append(missing, "discovery URL")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("pairing publisher is missing %s", strings.Join(missing, ", "))
	}

	parsed, err := url.Parse(strings.TrimSpace(config.DiscoveryURL))
	if err != nil {
		return nil, fmt.Errorf("discovery URL is not a valid URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("discovery URL must include a scheme and host, got %q", config.DiscoveryURL)
	}
	discoveryScheme, discoveryHost := parsed.Scheme, parsed.Host

	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: publishTimeout}
	}

	return &Publisher{
		config:          config,
		httpClient:      httpClient,
		discoveryScheme: discoveryScheme,
		discoveryHost:   discoveryHost,
	}, nil
}

// Seals the deployment description and stores it where the pairing device is
// polling.
//
// Nothing is returned to the caller. The record opens under the pairing
// secret, which the authorizing device already has from the QR, so handing
// the bytes back would not tell it anything it could not already produce.
func (p *Publisher) Publish(ctx context.Context, secret Secret) error {
	caPEM, err := os.ReadFile(p.config.CACertPath)
	if err != nil {
		return fmt.Errorf("read CA certificate for the pairing record: %w", err)
	}

	sealed, err := pairingblob.Seal(secret, Payload{
		HeadscaleURL: p.config.HeadscaleURL,
		CAPEM:        string(caPEM),
	})
	if err != nil {
		return err
	}
	return p.store(ctx, secret.Slot(), sealed)
}

// Publishes a record from the secret as it appears in a scanned QR code.
//
// This is the form gitd's HTTP endpoint receives, so parsing the secret happens
// here rather than in the handler: a truncated or mistyped scan is a pairing
// problem, and keeping the parse next to the publish means the handler does not
// have to know the secret's encoding.
func (p *Publisher) PublishPairingRecord(ctx context.Context, pairingSecret string) error {
	secret, err := pairingblob.ParseSecret(pairingSecret)
	if err != nil {
		return fmt.Errorf("the scanned pairing secret is not usable: %w", err)
	}
	return p.Publish(ctx, secret)
}

// Writes the sealed record to its slot.
func (p *Publisher) store(ctx context.Context, slot string, record []byte) error {
	endpoint := fmt.Sprintf("%s://%s.%s/", p.discoveryScheme, slot, p.discoveryHost)

	request, err := http.NewRequestWithContext(ctx, http.MethodPut, endpoint, bytes.NewReader(record))
	if err != nil {
		return fmt.Errorf("build discovery request: %w", err)
	}
	// The discovery API stores records as opaque bytes and rejects anything
	// that claims to be structured, since it must never be able to read them.
	request.Header.Set("Content-Type", recordContentType)

	response, err := p.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("publish pairing record: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusNoContent {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, maxErrorBodyBytes))
		return fmt.Errorf("discovery API returned %d when storing the pairing record: %s",
			response.StatusCode, strings.TrimSpace(string(detail)))
	}
	return nil
}
