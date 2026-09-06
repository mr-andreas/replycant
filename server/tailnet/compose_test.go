package tailnet_test

import (
	"os"
	"regexp"
	"testing"
)

// hsproxy is reached by two different names: the tunnel hostname when a device
// is bootstrapping, and gitd's MagicDNS name once it is on the tailnet and
// talking to the in-tailnet control relay. One certificate serves both, so it
// has to carry both SANs or the tailnet path fails verification and every
// device silently falls back to the relay forever.
func TestHsproxyCertificateCoversTheTailnetName(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	// The call spans a continuation line, so the match runs to the end of the
	// enclosing if block rather than to the first newline.
	issuance := regexp.MustCompile(`(?s)issue_cert hsproxy .*?\n\s*fi`).Find(compose)
	if issuance == nil {
		t.Fatal("server-key must issue an hsproxy certificate")
	}
	if !regexp.MustCompile(`DNS:\$\$\{GITD_TAILNET_NAME\}`).Match(issuance) {
		t.Errorf("hsproxy's certificate must include the tailnet name as a SAN, got %q",
			issuance)
	}

	// The reissue guard has to know about the name too, or an existing
	// deployment keeps its old certificate and never gains the SAN.
	guard := regexp.MustCompile(`(?s)cert_covers hsproxy\.crt[^\n]*\n`).Find(compose)
	if guard == nil {
		t.Fatal("server-key must guard hsproxy certificate reissue")
	}
	if !regexp.MustCompile(`\$\$\{GITD_TAILNET_NAME\}`).Match(guard) {
		t.Errorf("the reissue guard must require the tailnet name, got %q", guard)
	}
}
