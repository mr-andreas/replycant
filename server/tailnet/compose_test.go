package tailnet_test

import (
	"os"
	"regexp"
	"strings"
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

// The hosted registration listener serves a self-signed certificate that
// names no shard host. Without this pin the agent verifies sNN against
// the system roots and every registration fails on the name check.
func TestTunnelAgentPinsTheHostedRelayCertificate(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	if !regexp.MustCompile(`--relay-ca=/data/relay-ca\.crt`).Match(compose) {
		t.Error("tunnel-agent must pin the hosted relay certificate")
	}
	if !regexp.MustCompile(`hosted-relay\.crt:/data/relay-ca\.crt`).Match(compose) {
		t.Error("compose must mount the hosted relay pin into the agent")
	}
}

// Home routers often cache NXDOMAIN from the hours before the shard
// records existed, and Docker uses that resolver. The agent has to
// ask a public resolver or a first-device join never reaches the relay.
func TestTunnelAgentUsesPublicDNS(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	agent := regexp.MustCompile(`(?s)\n  tunnel-agent:\n(.*?\n)  [a-z]`).FindSubmatch(compose)
	if agent == nil {
		t.Fatal("compose must declare a tunnel-agent service")
	}
	body := string(agent[1])
	if !regexp.MustCompile(`(?m)^\s+dns:\n\s+- 1\.1\.1\.1\n\s+- 8\.8\.8\.8`).MatchString(body) {
		t.Error("tunnel-agent must resolve the relay hostname through public DNS")
	}
}

// A plain `docker compose up` has to start the hosted relay. Gating the
// agent on a profile meant a `.env` that only set a hostname never
// published headscale, and the first device hung at NeedsLogin.
func TestTunnelAgentStartsWithoutAProfile(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	agent := regexp.MustCompile(`(?s)\n  tunnel-agent:\n(.*?\n)  [a-z]`).FindSubmatch(compose)
	if agent == nil {
		t.Fatal("compose must declare a tunnel-agent service")
	}
	if regexp.MustCompile(`(?m)^\s+profiles:`).Match(agent[1]) {
		t.Error("tunnel-agent must start on a default compose up, not behind a profile")
	}
}

// The first device has no tailnet yet, so the only way to show it the join
// QR is a host-published CA page. It defaults to every interface so a server
// without a browser can be bootstrapped from another machine on the LAN;
// REPLYCANT_CA_BIND=127.0.0.1 keeps it local. That default is tolerable only
// because the page stops minting at the first push. Publishing the Git port
// would put gitd back on the internet.
//
// gitd must listen on the fixed container port the mapping targets, or a
// custom REPLYCANT_CA_PORT would publish a port nothing answers on.
func TestGitdPublishesOnlyTheCAPortOnAllInterfacesByDefault(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	gitd := regexp.MustCompile(`(?s)\n  gitd:\n(.*?\n)  [a-z]`).FindSubmatch(compose)
	if gitd == nil {
		t.Fatal("compose must declare a gitd service")
	}
	body := string(gitd[1])

	if !regexp.MustCompile(`"\$\{REPLYCANT_CA_BIND:-0\.0\.0\.0\}:\$\{REPLYCANT_CA_PORT:-8080\}:8080"`).MatchString(body) {
		t.Error("gitd must publish the CA listener on ${REPLYCANT_CA_BIND:-0.0.0.0}, defaulting to all interfaces")
	}
	if !strings.Contains(body, "--ca-addr=:8080 ") {
		t.Error("gitd must listen for the CA page on the container port the mapping targets")
	}
	if regexp.MustCompile(`8443:8443`).MatchString(body) {
		t.Error("gitd must not publish the Git listener; it is reachable only on the tailnet")
	}
}

// Returns one service's block from the compose file, so a test can assert on
// that service alone rather than on a flag that might belong to another.
func composeService(t *testing.T, name string) string {
	t.Helper()
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}
	service := regexp.MustCompile(`(?s)\n  ` + regexp.QuoteMeta(name) + `:\n(.*?\n)(  [a-z]|[a-z])`).
		FindSubmatch(compose)
	if service == nil {
		t.Fatalf("compose must declare a %s service", name)
	}
	return string(service[1])
}

// gitd mints its own tailnet key over headscale's API whenever its node needs
// one, so a key captured at init would be a second, stale source of truth.
// It would also be exactly the state a headscale wipe invalidates.
func TestNoTailnetKeyIsCapturedAtInit(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}
	for _, stale := range []string{"gitd.authkey", "preauthkeys create", "--tsnet-auth-key-file"} {
		if regexp.MustCompile(regexp.QuoteMeta(stale)).Match(compose) {
			t.Errorf("compose must not mention %q; tailnet keys are minted on demand", stale)
		}
	}
}

// Wiping headscale's database also deletes its API keys, while the key file on
// disk survives. headscale-init has to notice the stored key is no longer
// known and mint a new one, or every mint after a wipe fails with 401.
func TestHeadscaleInitReplacesAnAPIKeyHeadscaleForgot(t *testing.T) {
	body := composeService(t, "headscale-init")

	if !regexp.MustCompile(`headscale apikeys list`).MatchString(body) {
		t.Error("headscale-init must check the stored API key against headscale apikeys list")
	}
	// headscale lists a key by its first 22 characters: hskey-api- and the
	// 12-character prefix.
	if !regexp.MustCompile(`cut -c1-22`).MatchString(body) {
		t.Error("headscale-init must compare the stored key's 22-character prefix")
	}
}

// Devices mint their own keys through hsproxy, which therefore needs the
// API key, and must not start before headscale-init has written it.
func TestHsproxyCanMintDeviceKeys(t *testing.T) {
	body := composeService(t, "hsproxy")

	for _, flag := range []string{
		`--headscale-api-url=http://headscale:8080`,
		`--headscale-api-key-file=/data/tailnet/headscale.apikey`,
	} {
		if !regexp.MustCompile(regexp.QuoteMeta(flag)).MatchString(body) {
			t.Errorf("hsproxy must be started with %s", flag)
		}
	}
	// The directory rather than the file, so a key headscale-init replaces
	// is visible without recreating the container.
	if !regexp.MustCompile(`/tailnet:/data/tailnet:ro`).MatchString(body) {
		t.Error("hsproxy must mount the tailnet directory holding the API key")
	}
	if !regexp.MustCompile(`(?s)headscale-init:\s*\n\s*condition: service_completed_successfully`).MatchString(body) {
		t.Error("hsproxy must wait for headscale-init to write the API key")
	}
}

// A phone restoring from a recovery key carries only the CA's hash and can
// reach nothing but hsproxy, so hsproxy has to send the CA in its chain.
func TestHsproxyServesTheCA(t *testing.T) {
	body := composeService(t, "hsproxy")
	if !regexp.MustCompile(`--ca=/data/ca\.crt`).MatchString(body) {
		t.Error("hsproxy must be started with --ca=/data/ca.crt")
	}
	if !regexp.MustCompile(`gitd/ca\.crt:/data/ca\.crt:ro`).MatchString(body) {
		t.Error("hsproxy must mount the deployment CA")
	}
}

// The noise key is the control plane's identity, and every client pins it.
// Keeping it out of the database directory is what lets an operator delete
// that directory without every node rejecting the restarted headscale.
func TestNoiseKeySurvivesADatabaseWipe(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}
	if !regexp.MustCompile(`private_key_path: /var/lib/headscale-noise/noise_private\.key`).Match(compose) {
		t.Error("headscale's noise key must live outside /var/lib/headscale")
	}
	if !regexp.MustCompile(`headscale/noise:/var/lib/headscale-noise`).MatchString(composeService(t, "headscale")) {
		t.Error("headscale must mount the noise key directory separately")
	}
}

// A long-running service that exits, for example gitd giving up on a tailnet
// join, must come back on its own. Otherwise the stack keeps running without
// it and devices see only an unreachable host.
func TestLongRunningServicesRestart(t *testing.T) {
	for _, name := range []string{"headscale", "hsproxy", "tunnel-agent", "gitd", "decryptd", "transcoded"} {
		if !regexp.MustCompile(`\n    restart: unless-stopped\n`).MatchString(composeService(t, name)) {
			t.Errorf("%s must declare restart: unless-stopped", name)
		}
	}
}

// Revocation compares pubkeys/ with the set gitd last reconciled. The marker
// must persist on a writable volume, or every gitd restart would drop all
// device nodes again.
func TestGitdKeepsItsReconcileMarker(t *testing.T) {
	body := composeService(t, "gitd")
	if !regexp.MustCompile(`--tailnet-reconcile-marker=/data/tailnet-state/reconciled-pubkeys\.json`).MatchString(body) {
		t.Error("gitd must be given a reconcile marker path")
	}
	if !regexp.MustCompile(`gitd/tailnet-state:/data/tailnet-state\n`).MatchString(body) {
		t.Error("gitd must mount a writable directory for the reconcile marker")
	}
}
