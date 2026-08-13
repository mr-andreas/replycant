package main

import (
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
