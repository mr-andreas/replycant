// Package pairing is gitd's writer side of the discovery handshake.
//
// A device that has never paired knows nothing about the deployment: not the
// CA, not where headscale is, and it has no way to get a tailnet credential.
// Everything it needs has to arrive in one record it can both decrypt and
// trust, published by something that already holds the deployment's secrets.
// That is gitd, which is why this lives here rather than in the hosted service.
//
// The record is published to a slot derived from the pairing secret shown in
// the QR code, so the discovery API never learns who a record is for and the
// slot never has to be transmitted. See pkg/pairing for the record format and
// why it carries two layers of encryption.
package pairing

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
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

// How long a minted pre-auth key stays usable.
//
// Deliberately short. The key is the one credential in the record that grants
// tailnet access, and it passes through a QR code that could be photographed
// and a discovery record that sits in a hosted database. Ten minutes is long
// enough for someone to finish scanning and joining, short enough that an
// abandoned pairing does not leave a usable credential behind.
const preauthKeyTTL = 10 * time.Minute

// How long to wait on the discovery API. Someone is watching a spinner.
const publishTimeout = 15 * time.Second

// How much of a failed response to quote back when reporting an error.
const maxErrorBodyBytes = 512

// Mints the single-use tailnet credential a pairing device needs.
//
// An interface so the publisher can be tested without a headscale, and so the
// headscale client stays the only thing that knows the control-plane API.
type Minter interface {
	MintPreauthKey(ctx context.Context, validFor time.Duration) (string, error)
}

// Everything gitd needs to describe its own deployment to a new device.
type Config struct {
	Minter Minter

	// Read at publish time rather than cached, so rotating the CA reaches
	// newly paired devices without restarting gitd.
	CACertPath string

	// Where the device should point its tailnet client. Either the tunnel
	// hostname or, in manual-exposure mode, the operator's own DNS name.
	HeadscaleURL string

	// The MagicDNS name the device will use to reach gitd once on the tailnet.
	GitdTailnetName string

	// headscale's MagicDNS base domain, needed by clients that resolve names
	// themselves rather than through the tailnet resolver.
	BaseDomain string

	// Base URL of the discovery API. The slot is prepended as a subdomain, so
	// this is the parent domain rather than a full record URL.
	//
	// Optional. Left empty the record is only returned to the caller, which is
	// manual-exposure mode: the authorizing device renders it as a QR for the
	// pairing device to scan, and no hosted service is involved at all.
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
	if config.Minter == nil {
		return nil, errors.New("a pre-auth key minter is required")
	}

	missing := make([]string, 0, 5)
	if strings.TrimSpace(config.CACertPath) == "" {
		missing = append(missing, "CA certificate path")
	}
	if strings.TrimSpace(config.HeadscaleURL) == "" {
		missing = append(missing, "headscale URL")
	}
	if strings.TrimSpace(config.GitdTailnetName) == "" {
		missing = append(missing, "gitd tailnet name")
	}
	if strings.TrimSpace(config.BaseDomain) == "" {
		missing = append(missing, "tailnet base domain")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("pairing publisher is missing %s", strings.Join(missing, ", "))
	}

	var discoveryScheme, discoveryHost string
	if raw := strings.TrimSpace(config.DiscoveryURL); raw != "" {
		parsed, err := url.Parse(raw)
		if err != nil {
			return nil, fmt.Errorf("discovery URL is not a valid URL: %w", err)
		}
		if parsed.Scheme == "" || parsed.Host == "" {
			return nil, fmt.Errorf("discovery URL must include a scheme and host, got %q", config.DiscoveryURL)
		}
		discoveryScheme, discoveryHost = parsed.Scheme, parsed.Host
	}

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

// Mints a credential and seals it with the rest of the deployment description,
// returning the record and, when cloud discovery is configured, also storing it
// where the pairing device is polling.
//
// The record is returned in both modes because it is safe to hand back: it is
// encrypted to the pairing device's key and authenticated under the pairing
// secret, so only the device that produced the QR can open it. That is what
// lets manual-exposure mode work with no hosted service at all, by having the
// authorizing device display the record as a QR instead.
//
// Ordering matters: nothing is published unless a key was minted successfully,
// because a record without a usable key would consume the device's single-use
// slot read and leave it with nothing to retry against.
func (p *Publisher) Publish(ctx context.Context, secret Secret, deviceAgePublicKey string) ([]byte, error) {
	recipient, err := decodeDeviceKey(deviceAgePublicKey)
	if err != nil {
		return nil, err
	}

	caPEM, err := os.ReadFile(p.config.CACertPath)
	if err != nil {
		return nil, fmt.Errorf("read CA certificate for the pairing record: %w", err)
	}

	preauthKey, err := p.config.Minter.MintPreauthKey(ctx, preauthKeyTTL)
	if err != nil {
		return nil, fmt.Errorf("mint a tailnet credential for the pairing device: %w", err)
	}

	sealed, err := pairingblob.Seal(secret, recipient, Payload{
		HeadscaleURL:    p.config.HeadscaleURL,
		CAPEM:           string(caPEM),
		PreauthKey:      preauthKey,
		GitdTailnetName: p.config.GitdTailnetName,
		BaseDomain:      p.config.BaseDomain,
	})
	if err != nil {
		return nil, err
	}

	if !p.discoveryConfigured() {
		return sealed, nil
	}
	if err := p.store(ctx, secret.Slot(), sealed); err != nil {
		return nil, err
	}
	return sealed, nil
}

// Reports whether records go to the hosted discovery API, as opposed to being
// handed back for the authorizing device to display as a QR.
func (p *Publisher) discoveryConfigured() bool {
	return p.discoveryHost != ""
}

// Publishes a record from the values as they appear in a scanned QR code.
//
// This is the form gitd's HTTP endpoint receives, so parsing the secret happens
// here rather than in the handler: a truncated or mistyped scan is a pairing
// problem, and keeping the parse next to the publish means the handler does not
// have to know the secret's encoding.
func (p *Publisher) PublishPairingRecord(ctx context.Context, pairingSecret, deviceAgePublicKey string) ([]byte, error) {
	secret, err := pairingblob.ParseSecret(pairingSecret)
	if err != nil {
		return nil, fmt.Errorf("the scanned pairing secret is not usable: %w", err)
	}
	return p.Publish(ctx, secret, deviceAgePublicKey)
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

// Converts the bech32 age recipient carried in the pairing QR into the raw key
// the record format needs.
//
// This is the first thing done with a scanned value, so a garbled or hostile QR
// is rejected before any credential is minted for it.
func decodeDeviceKey(agePublicKey string) ([]byte, error) {
	trimmed := strings.TrimSpace(agePublicKey)
	if trimmed == "" {
		return nil, errors.New("the pairing device's age public key is required")
	}
	recipient, err := gitcrypt.DecodeAgePublicKey(trimmed)
	if err != nil {
		return nil, fmt.Errorf("the pairing device's age public key is not a valid age recipient: %w", err)
	}
	return recipient, nil
}
