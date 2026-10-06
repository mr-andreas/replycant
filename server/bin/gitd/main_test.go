package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
)

// Everything gitd needs besides what a test is about. gitd only runs on a
// tailnet, so the tailnet and headscale flags are part of the minimum.
func requiredArgs(t *testing.T) []string {
	t.Helper()
	dir := t.TempDir()
	return []string{
		"--repo", dir,
		"--cert", dir,
		"--key", dir,
		"--ca", dir,
		"--lfs-dir", dir,
		"--decryptd-url", "http://decryptd:8084",
		"--transcoded-url", "http://transcoded:8082",
		"--tsnet-dir", filepath.Join(dir, "tsnet"),
		"--tsnet-control-url", "http://headscale:8080",
		"--headscale-api-url", "http://headscale:8080",
		"--headscale-api-key-file", filepath.Join(dir, "apikey"),
		"--headscale-client-url", "https://example.tunnel.replycant.com",
		"--tailnet-reconcile-marker", filepath.Join(dir, "reconciled-pubkeys.json"),
	}
}

func parseCLI(t *testing.T, args ...string) (CLI, error) {
	t.Helper()
	var cli CLI
	parser, err := kong.New(&cli)
	if err != nil {
		t.Fatalf("kong.New() error = %v", err)
	}
	_, err = parser.Parse(args)
	return cli, err
}

// Confirms the CA listener still defaults to :8080 when --ca-addr is omitted.
func TestCLIDefaultCaAddr(t *testing.T) {
	cli, err := parseCLI(t, requiredArgs(t)...)
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if cli.CaAddr != ":8080" {
		t.Fatalf("CaAddr default = %q, want %q", cli.CaAddr, ":8080")
	}
}

// Compose and the docs pass --headscale-api-url. Kong would otherwise
// hyphenate HeadscaleAPIURL as --headscale-apiurl, which is what made
// gitd refuse to start after the image was rebuilt.
func TestHeadscaleAPIURLAcceptsTheComposeFlagName(t *testing.T) {
	cli, err := parseCLI(t, requiredArgs(t)...)
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if cli.HeadscaleAPIURL != "http://headscale:8080" {
		t.Fatalf("HeadscaleAPIURL = %q, want the value passed as --headscale-api-url",
			cli.HeadscaleAPIURL)
	}
}

// gitd's Git listener exists only on the tailnet, and it mints its own
// tailnet key over the headscale API, so a deployment missing any of those
// flags could serve nobody. Each one is refused at startup.
func TestTailnetFlagsAreRequired(t *testing.T) {
	for _, flag := range []string{
		"--tsnet-dir",
		"--tsnet-control-url",
		"--headscale-api-url",
		"--headscale-api-key-file",
		"--headscale-client-url",
		"--tailnet-reconcile-marker",
	} {
		t.Run(flag, func(t *testing.T) {
			args := requiredArgs(t)
			for i := range args {
				if args[i] == flag {
					args = append(args[:i], args[i+2:]...)
					break
				}
			}
			if _, err := parseCLI(t, args...); err == nil {
				t.Fatalf("expected %s to be required", flag)
			}
		})
	}
}

// The tsnet flags have to reach the node config unchanged, since a wrong
// control URL would silently join the wrong tailnet. The node name is fixed,
// because clients and certificates only know gitd by that name.
func TestTsnetConfigFromFlags(t *testing.T) {
	cli, err := parseCLI(t, requiredArgs(t)...)
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	config := cli.tsnetConfig()
	if config.Dir != cli.TsnetDir || config.ControlURL != "http://headscale:8080" {
		t.Fatalf("tsnet config %+v does not match the flags", config)
	}
	if config.Hostname != tailnetaddr.GitdHostname {
		t.Fatalf("Hostname = %q, want %q", config.Hostname, tailnetaddr.GitdHostname)
	}
}

// A control URL that is not a URL would leave gitd waiting on a join that
// can never start.
func TestValidateRejectsAControlURLThatIsNotAURL(t *testing.T) {
	args := append(requiredArgs(t), "--tsnet-control-url", "headscale:8080")
	if _, err := parseCLI(t, args...); err == nil {
		t.Fatal("expected a control URL without a scheme to be rejected")
	}
}

// Manual-exposure mode is the default flags without a discovery URL. gitd
// still seals pairing records; it just hands them back for the authorizing
// device to display instead of publishing them.
func TestManualExposureModeNeedsNoDiscoveryURL(t *testing.T) {
	cli, err := parseCLI(t, requiredArgs(t)...)
	if err != nil {
		t.Fatalf("manual-exposure mode must be a valid configuration: %v", err)
	}
	if cli.DiscoveryURL != "" {
		t.Fatalf("DiscoveryURL default = %q, want empty", cli.DiscoveryURL)
	}
}

// Writes an API key so a headscale client can be built, as headscale-init
// would have.
func cliWithAPIKey(t *testing.T) CLI {
	t.Helper()
	dir := t.TempDir()
	apiKeyPath := filepath.Join(dir, "headscale.apikey")
	if err := os.WriteFile(apiKeyPath, []byte("test-api-key\n"), 0o600); err != nil {
		t.Fatalf("write API key: %v", err)
	}
	return CLI{
		Repo:                   dir,
		CA:                     filepath.Join(dir, "ca.crt"),
		HeadscaleAPIURL:        "http://headscale:8080",
		HeadscaleAPIKeyFile:    apiKeyPath,
		HeadscaleClientURL:     "https://abc.tunnel.replycant.com",
		HeadscaleUser:          "replycant",
		TailnetReconcileMarker: filepath.Join(dir, "reconciled-pubkeys.json"),
	}
}

// Pushes have to drive revocation, so the reconciler must be built from the
// same flags that build the client.
func TestReconcilerIsBuiltWithHeadscale(t *testing.T) {
	cli := cliWithAPIKey(t)
	headscale, err := cli.headscaleClient()
	if err != nil {
		t.Fatalf("build headscale client: %v", err)
	}
	if _, err := cli.buildReconciler(headscale); err != nil {
		t.Fatalf("build reconciler: %v", err)
	}
}

// Both delivery modes need a publisher: it mints the credential and seals the
// record, whether it is then published or displayed.
func TestBothDeliveryModesBuildAPublisher(t *testing.T) {
	for _, discoveryURL := range []string{"", "https://discovery.replycant.com"} {
		cli := cliWithAPIKey(t)
		cli.DiscoveryURL = discoveryURL
		if _, err := cli.buildPairingPublisher(); err != nil {
			t.Fatalf("discovery URL %q must build a publisher: %v", discoveryURL, err)
		}
	}
}

// An unreadable API key file means headscale-init has not run. Reporting it at
// startup avoids a deployment that looks healthy until someone pairs.
func TestMissingHeadscaleAPIKeyFailsStartup(t *testing.T) {
	cli := cliWithAPIKey(t)
	cli.HeadscaleAPIKeyFile = filepath.Join(t.TempDir(), "absent.apikey")
	if _, err := cli.headscaleClient(); err == nil {
		t.Fatal("a missing headscale API key must fail startup")
	}
}
