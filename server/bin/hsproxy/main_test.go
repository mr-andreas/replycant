package main

import (
	"testing"

	"github.com/alecthomas/kong"
)

// docker-compose.yaml and the integration harness start hsproxy with these
// exact flags. Kong derives flag names from field names, and an acronym like
// APIURL silently becomes `apiurl`, so a rename here would only show up as
// hsproxy refusing to start in a deployment.
func TestParsesTheHeadscaleAPIFlagsComposeUses(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli)
	if err != nil {
		t.Fatalf("kong.New() error = %v", err)
	}
	_, err = parser.Parse([]string{
		"--repo=/data/repo",
		"--upstream=headscale:8080",
		"--cert=/data/hsproxy.crt",
		"--key=/data/hsproxy.key",
		"--headscale-api-url=http://headscale:8080",
		"--headscale-api-key-file=/data/tailnet/headscale.apikey",
	})
	if err != nil {
		t.Fatalf("hsproxy must accept the flags compose passes: %v", err)
	}
	if cli.HeadscaleAPIURL != "http://headscale:8080" {
		t.Errorf("expected the API URL to be parsed, got %q", cli.HeadscaleAPIURL)
	}
	if cli.HeadscaleAPIKeyFile != "/data/tailnet/headscale.apikey" {
		t.Errorf("expected the API key file to be parsed, got %q", cli.HeadscaleAPIKeyFile)
	}
}
