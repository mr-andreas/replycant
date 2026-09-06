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

// The hostname devices dial has to name the shard the CA hashes to, because
// only one relay in the fleet holds this deployment's registration. Getting
// the shard out of the hostname would send every device to a relay that has
// never heard of the deployment.
func TestHeadscaleHostnameCarriesTheShardLabel(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	assignment := regexp.MustCompile(`HEADSCALE_HOST="[^"]*TUNNEL_DOMAIN\}"`).Find(compose)
	if assignment == nil {
		t.Fatal("server-key must derive HEADSCALE_HOST from the tunnel domain")
	}
	want := `HEADSCALE_HOST="$${CA_LABEL}.$${CA_SHARD}.$${REPLYCANT_TUNNEL_DOMAIN}"`
	if string(assignment) != want {
		t.Errorf("HEADSCALE_HOST must be %s, got %s", want, assignment)
	}
}

// The agent registers with one relay and devices are sent to one relay, and
// they have to be the same one. Deriving both from CA_SHARD is what guarantees
// that; a compose-level default would silently point the agent elsewhere.
func TestTunnelAgentRegistersWithTheDerivedShard(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	derivation := regexp.MustCompile(`TUNNEL_RELAY_ADDR="\$\$\{CA_SHARD\}\.\$\$\{REPLYCANT_TUNNEL_DOMAIN\}:8444"`)
	if !derivation.Match(compose) {
		t.Error("server-key must derive the relay address from the shard label")
	}

	// The override is what keeps self-hosted relays possible, so it has to
	// survive the derivation being added.
	if !regexp.MustCompile(`if \[ -n "\$\$\{REPLYCANT_TUNNEL_RELAY_ADDR\}" \]`).Match(compose) {
		t.Error("REPLYCANT_TUNNEL_RELAY_ADDR must stay an override")
	}

	// The agent has to read the derived value rather than derive it again,
	// which would be a second place to get the modulus wrong.
	if !regexp.MustCompile(`--relay-addr="\$\$REPLYCANT_TUNNEL_RELAY_ADDR"`).Match(compose) {
		t.Error("tunnel-agent must take its relay address from tailnet.env")
	}
	if !regexp.MustCompile(`REPLYCANT_TUNNEL_RELAY_ADDR=\$\$\{TUNNEL_RELAY_ADDR\}`).Match(compose) {
		t.Error("server-key must publish the relay address in tailnet.env")
	}
}
