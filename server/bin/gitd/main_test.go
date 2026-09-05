package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alecthomas/kong"
)

// Confirms QR and /config.json advertise the Git listen port so clients
// do not keep connecting to 8443 after an operator remaps gitd.
func TestAdvertisedServerURLIncludesCustomGitPort(t *testing.T) {
	got := advertisedServerURL("replycant.local", ":9443")
	want := "https://replycant.local:9443/"
	if got != want {
		t.Fatalf("advertisedServerURL() = %q, want %q", got, want)
	}
}

// Confirms the CA listener still defaults to :8080 when --ca-addr is omitted.
func TestCLIDefaultCaAddr(t *testing.T) {
	dir := t.TempDir()
	var cli CLI
	parser, err := kong.New(&cli)
	if err != nil {
		t.Fatalf("kong.New() error = %v", err)
	}
	_, err = parser.Parse([]string{
		"--repo", dir,
		"--cert", dir,
		"--key", dir,
		"--ca", dir,
		"--hostname", "host",
		"--lfs-dir", dir,
		"--decryptd-url", "http://decryptd:8084",
		"--transcoded-url", "http://transcoded:8082",
	})
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if cli.CaAddr != ":8080" {
		t.Fatalf("CaAddr default = %q, want %q", cli.CaAddr, ":8080")
	}
}

// Parses a minimal flag set so tsnet tests only have to state what they care
// about, keeping the required-flag noise in one place.
func parseCLI(t *testing.T, extraArgs ...string) CLI {
	t.Helper()

	dir := t.TempDir()
	var cli CLI
	parser, err := kong.New(&cli)
	if err != nil {
		t.Fatalf("kong.New() error = %v", err)
	}
	args := []string{
		"--repo", dir,
		"--cert", dir,
		"--key", dir,
		"--ca", dir,
		"--hostname", "host",
		"--lfs-dir", dir,
		"--decryptd-url", "http://decryptd:8084",
		"--transcoded-url", "http://transcoded:8082",
	}
	if _, err := parser.Parse(append(args, extraArgs...)); err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	return cli
}

// Omitting --tsnet-dir has to keep gitd listening on a host port, because that
// is what integration tests and LAN-only deployments rely on.
func TestTsnetDisabledByDefault(t *testing.T) {
	cli := parseCLI(t)
	if cli.tsnetConfig().Enabled() {
		t.Fatal("tsnet must be disabled when --tsnet-dir is omitted")
	}
	if err := cli.Validate(); err != nil {
		t.Fatalf("a config without tsnet must validate: %v", err)
	}
}

// The tsnet flags have to reach the node config unchanged, since a wrong
// control URL would silently join the wrong tailnet.
func TestTsnetConfigFromFlags(t *testing.T) {
	cli := parseCLI(t,
		"--tsnet-dir", "/var/lib/replycant/tsnet",
		"--tsnet-control-url", "http://headscale:8080",
		"--tsnet-hostname", "gitd",
		"--tsnet-auth-key-file", "/run/secrets/authkey",
		"--tailnet-domain", "replycant.internal",
	)

	config := cli.tsnetConfig()
	if !config.Enabled() {
		t.Fatal("expected tsnet to be enabled")
	}
	if config.Dir != "/var/lib/replycant/tsnet" {
		t.Fatalf("Dir = %q", config.Dir)
	}
	if config.ControlURL != "http://headscale:8080" {
		t.Fatalf("ControlURL = %q", config.ControlURL)
	}
	if config.Hostname != "gitd" {
		t.Fatalf("Hostname = %q", config.Hostname)
	}
	if config.AuthKeyFile != "/run/secrets/authkey" {
		t.Fatalf("AuthKeyFile = %q", config.AuthKeyFile)
	}
}

// An incomplete tsnet configuration must be rejected. If it were accepted,
// gitd would come up with no listener any device can reach.
//
// Validate is called directly rather than through the parser because kong runs
// it during Parse, which would hide which check fired.
func TestValidateRejectsIncompleteTsnetConfig(t *testing.T) {
	cases := []struct {
		name string
		cli  CLI
	}{
		{
			name: "no control url",
			cli:  CLI{Hostname: "host", TsnetDir: "/state", TsnetHostname: "gitd", TailnetDomain: "replycant.internal"},
		},
		{
			name: "no tsnet hostname",
			cli:  CLI{Hostname: "host", TsnetDir: "/state", TsnetControlURL: "http://headscale:8080", TailnetDomain: "replycant.internal"},
		},
		{
			name: "control url is not a url",
			cli:  CLI{Hostname: "host", TsnetDir: "/state", TsnetHostname: "gitd", TsnetControlURL: "headscale:8080", TailnetDomain: "replycant.internal"},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if err := testCase.cli.Validate(); err == nil {
				t.Fatal("expected validation to reject the incomplete tsnet config")
			}
		})
	}
}

// With tsnet enabled the advertised URL must name the MagicDNS host, because
// the LAN hostname no longer resolves to a reachable listener.
func TestAdvertisedServerURLPrefersTailnetHostname(t *testing.T) {
	cli := parseCLI(t,
		"--tsnet-dir", "/state",
		"--tsnet-control-url", "http://headscale:8080",
		"--tsnet-hostname", "gitd",
		"--tailnet-domain", "replycant.internal",
	)

	got := cli.advertisedURL()
	want := "https://gitd.replycant.internal:8443/"
	if got != want {
		t.Fatalf("advertisedURL() = %q, want %q", got, want)
	}
}

// Without tsnet the advertised URL must stay on the configured LAN hostname so
// existing LAN-only setups keep working unchanged.
func TestAdvertisedServerURLFallsBackToLanHostname(t *testing.T) {
	cli := parseCLI(t, "--addr", ":9443")

	got := cli.advertisedURL()
	want := "https://host:9443/"
	if got != want {
		t.Fatalf("advertisedURL() = %q, want %q", got, want)
	}
}

// A tailnet deployment without a MagicDNS domain would advertise a bare
// hostname that only resolves for peers with the right search domain, so the
// domain is required once tsnet is on.
func TestValidateRequiresTailnetDomainWithTsnet(t *testing.T) {
	cli := CLI{
		Hostname:        "host",
		TsnetDir:        "/state",
		TsnetControlURL: "http://headscale:8080",
		TsnetHostname:   "gitd",
	}
	if err := cli.Validate(); err == nil {
		t.Fatal("expected validation to require --tailnet-domain when tsnet is enabled")
	}
}

// A deployment with no tailnet at all - LAN-only, and the integration harness
// - must stay valid, so "none of the flags" cannot be an error.
func TestNoTailnetNeedsNoPairingFlags(t *testing.T) {
	cli := CLI{Hostname: "host"}
	if err := cli.validateDiscovery(); err != nil {
		t.Fatalf("a LAN-only deployment must be a valid configuration: %v", err)
	}
	if cli.pairingEnabled() {
		t.Error("pairing must be off when no headscale flags are set")
	}
}

// Manual-exposure mode is the headscale flags without a discovery URL. gitd
// still mints credentials; it just hands the record back for the authorizing
// device to display instead of publishing it.
func TestManualExposureModeNeedsNoDiscoveryURL(t *testing.T) {
	cli := CLI{
		Hostname:            "host",
		HeadscaleAPIURL:     "http://headscale:8080",
		HeadscaleAPIKeyFile: "/data/tailnet/headscale.apikey",
		HeadscaleClientURL:  "https://headscale.example.com",
	}
	if err := cli.validateDiscovery(); err != nil {
		t.Fatalf("manual-exposure mode must be a valid configuration: %v", err)
	}
	if !cli.pairingEnabled() {
		t.Error("manual-exposure mode still needs to mint credentials")
	}
}

// A discovery URL with no way to mint a credential would leave gitd with
// nothing to publish, so it is caught rather than accepted.
func TestDiscoveryURLAloneIsRejected(t *testing.T) {
	cli := CLI{Hostname: "host", DiscoveryURL: "https://discovery.replycant.com"}
	err := cli.validateDiscovery()
	if err == nil {
		t.Fatal("a discovery URL without headscale flags must be rejected")
	}
	if !strings.Contains(err.Error(), "--discovery-url") {
		t.Errorf("the error should name the offending flag, got %v", err)
	}
}

// A partial configuration would start cleanly and then fail at the moment
// someone tries to pair a device. Failing at startup instead means the
// operator finds out while they are still looking at the logs.
func TestPartialDiscoveryConfigIsRejected(t *testing.T) {
	complete := CLI{
		Hostname:            "host",
		DiscoveryURL:        "https://discovery.replycant.com",
		HeadscaleAPIURL:     "http://headscale:8080",
		HeadscaleAPIKeyFile: "/data/tailnet/headscale.apikey",
		HeadscaleClientURL:  "https://abc.tunnel.replycant.com",
	}
	if err := complete.validateDiscovery(); err != nil {
		t.Fatalf("a complete discovery config must be accepted: %v", err)
	}

	for _, testCase := range []struct {
		name    string
		mutate  func(*CLI)
		wantsIn string
	}{
		{"no headscale API URL", func(c *CLI) { c.HeadscaleAPIURL = "" }, "--headscale-api-url"},
		{"no API key file", func(c *CLI) { c.HeadscaleAPIKeyFile = "" }, "--headscale-api-key-file"},
		{"no client URL", func(c *CLI) { c.HeadscaleClientURL = "" }, "--headscale-client-url"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			cli := complete
			testCase.mutate(&cli)

			err := cli.validateDiscovery()
			if err == nil {
				t.Fatal("a partial discovery config must be rejected")
			}
			if !strings.Contains(err.Error(), testCase.wantsIn) {
				t.Errorf("the error should name the missing flag %s, got %v", testCase.wantsIn, err)
			}
		})
	}
}

// A device is told where to find gitd twice: in the pairing record and in
// /config.json. If those disagreed, a freshly paired device would join the
// tailnet and then fail to reach the server, so both must come from one place.
func TestTailnetHostnameIsSharedWithTheAdvertisedURL(t *testing.T) {
	dir := t.TempDir()
	cli := CLI{
		Hostname:      "replycant.local",
		Addr:          ":8443",
		TsnetDir:      dir,
		TsnetHostname: "gitd",
		TailnetDomain: "replycant.internal",
	}

	hostname := cli.tailnetHostname()
	if hostname != "gitd.replycant.internal" {
		t.Fatalf("unexpected tailnet hostname %q", hostname)
	}
	if advertised := cli.advertisedURL(); !strings.Contains(advertised, hostname) {
		t.Errorf("the advertised URL %q must use the tailnet hostname %q", advertised, hostname)
	}
}

// A trailing dot is a legitimate way to write a fully qualified domain, and
// compose interpolation makes it easy to introduce. Left in place it would
// produce a double-dotted name that resolves nowhere.
func TestTailnetHostnameToleratesADottedDomain(t *testing.T) {
	cli := CLI{TsnetHostname: "gitd", TailnetDomain: ".replycant.internal."}
	if got := cli.tailnetHostname(); got != "gitd.replycant.internal" {
		t.Errorf("unexpected tailnet hostname %q", got)
	}
}

// A deployment with no tailnet must leave the publisher nil, because that nil
// is what makes gitd answer 404 on /pair rather than offering an endpoint that
// cannot work.
func TestNoPublisherIsBuiltWithoutATailnet(t *testing.T) {
	cli := CLI{Hostname: "host"}
	publisher, err := cli.buildPairingPublisher()
	if err != nil {
		t.Fatalf("a LAN-only deployment must not fail to build: %v", err)
	}
	if publisher != nil {
		t.Error("a deployment without a tailnet must not install a pairing publisher")
	}
}

// Manual-exposure mode must still install a publisher, since it is what mints
// the credential and seals the record the authorizing device displays.
func TestManualModeBuildsAPublisher(t *testing.T) {
	dir := t.TempDir()
	apiKeyPath := filepath.Join(dir, "headscale.apikey")
	if err := os.WriteFile(apiKeyPath, []byte("test-api-key\n"), 0o600); err != nil {
		t.Fatalf("write API key: %v", err)
	}

	cli := CLI{
		Hostname:            "host",
		TsnetHostname:       "gitd",
		TailnetDomain:       "replycant.internal",
		CA:                  filepath.Join(dir, "ca.crt"),
		HeadscaleAPIURL:     "http://headscale:8080",
		HeadscaleAPIKeyFile: apiKeyPath,
		HeadscaleClientURL:  "https://headscale.example.com",
		HeadscaleUser:       "replycant",
	}
	publisher, err := cli.buildPairingPublisher()
	if err != nil {
		t.Fatalf("manual-exposure mode must build a publisher: %v", err)
	}
	if publisher == nil {
		t.Fatal("manual-exposure mode needs a publisher to mint and seal")
	}
}

// An unreadable API key file means headscale-init has not run. Reporting it at
// startup avoids a deployment that looks healthy until someone pairs.
func TestMissingHeadscaleAPIKeyFailsStartup(t *testing.T) {
	cli := CLI{
		Hostname:            "host",
		TsnetHostname:       "gitd",
		TailnetDomain:       "replycant.internal",
		CA:                  filepath.Join(t.TempDir(), "ca.crt"),
		DiscoveryURL:        "https://discovery.replycant.com",
		HeadscaleAPIURL:     "http://headscale:8080",
		HeadscaleAPIKeyFile: filepath.Join(t.TempDir(), "absent.apikey"),
		HeadscaleClientURL:  "https://abc.tunnel.replycant.com",
	}
	if _, err := cli.buildPairingPublisher(); err == nil {
		t.Fatal("a missing headscale API key must fail startup")
	}
}

// The full cloud configuration must actually produce a working publisher, so
// that the manual-mode tests above are proving a distinction rather than
// covering a path that never works.
func TestCloudModeBuildsAPublisher(t *testing.T) {
	dir := t.TempDir()
	apiKeyPath := filepath.Join(dir, "headscale.apikey")
	if err := os.WriteFile(apiKeyPath, []byte("test-api-key\n"), 0o600); err != nil {
		t.Fatalf("write API key: %v", err)
	}

	cli := CLI{
		Hostname:            "host",
		TsnetHostname:       "gitd",
		TailnetDomain:       "replycant.internal",
		CA:                  filepath.Join(dir, "ca.crt"),
		DiscoveryURL:        "https://discovery.replycant.com",
		HeadscaleAPIURL:     "http://headscale:8080",
		HeadscaleAPIKeyFile: apiKeyPath,
		HeadscaleClientURL:  "https://abc.tunnel.replycant.com",
		HeadscaleUser:       "replycant",
	}
	publisher, err := cli.buildPairingPublisher()
	if err != nil {
		t.Fatalf("a complete cloud config must build a publisher: %v", err)
	}
	if publisher == nil {
		t.Fatal("cloud mode must install a pairing publisher")
	}
}
