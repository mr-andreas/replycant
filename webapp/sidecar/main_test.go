package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// A complete configuration, as Electron would send it.
func validInput() map[string]string {
	return map[string]string{
		"headscale_addr":        "abc.tunnel.replycant.com:443",
		"headscale_server_name": "abc.tunnel.replycant.com",
		"ca_pem":                "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----",
		"client_cert_pem":       "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----",
		"client_key_pem":        "-----BEGIN EC PRIVATE KEY-----\nZmFrZQ==\n-----END EC PRIVATE KEY-----",
		"preauth_key":           "hskey-auth-example",
		"state_dir":             "/tmp/replycant/tsnet",
		"hostname":              "desktop",
	}
}

func encode(t *testing.T, value any) *strings.Reader {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("encode input: %v", err)
	}
	return strings.NewReader(string(raw))
}

// The configuration carries the device's private key, so it arrives on stdin
// rather than as flags. This confirms the reader accepts what Electron sends.
func TestReadInputAcceptsACompleteConfiguration(t *testing.T) {
	config, err := readInput(encode(t, validInput()))
	if err != nil {
		t.Fatalf("a complete configuration must be accepted: %v", err)
	}

	if config.HeadscaleAddr != "abc.tunnel.replycant.com:443" {
		t.Errorf("unexpected headscale address %q", config.HeadscaleAddr)
	}
	if config.Hostname != "desktop" {
		t.Errorf("unexpected hostname %q", config.Hostname)
	}
	if config.StateDir != "/tmp/replycant/tsnet" {
		t.Errorf("unexpected state directory %q", config.StateDir)
	}
}

// Each missing field would otherwise surface as a confusing TLS or join
// failure much later, so the reader names the field instead.
func TestReadInputRejectsMissingFields(t *testing.T) {
	for _, field := range []string{
		"headscale_addr",
		"ca_pem",
		"client_cert_pem",
		"client_key_pem",
		"state_dir",
		"hostname",
	} {
		t.Run(field, func(t *testing.T) {
			config := validInput()
			delete(config, field)

			_, err := readInput(encode(t, config))
			if err == nil {
				t.Fatalf("a configuration without %s must be rejected", field)
			}
			if !strings.Contains(err.Error(), field) {
				t.Errorf("the error should name %s, got %v", field, err)
			}
		})
	}
}

// Blank values come from templating in the parent process and would otherwise
// pass a presence check while still being unusable.
func TestReadInputRejectsBlankFields(t *testing.T) {
	config := validInput()
	config["ca_pem"] = "   \n"

	if _, err := readInput(encode(t, config)); err == nil {
		t.Fatal("a blank CA must be rejected")
	}
}

// The pre-auth key is only needed for the first join. Requiring it afterwards
// would make every restart fail, since the credential is single-use.
func TestReadInputAcceptsAMissingPreauthKey(t *testing.T) {
	config := validInput()
	delete(config, "preauth_key")

	parsed, err := readInput(encode(t, config))
	if err != nil {
		t.Fatalf("a rejoining node has no pre-auth key: %v", err)
	}
	if parsed.PreauthKey != "" {
		t.Errorf("expected no pre-auth key, got one")
	}
}

// A relative state directory would resolve against whatever directory Electron
// was launched from, so the node identity would not survive a restart and each
// launch would need a fresh single-use credential it does not have.
func TestReadInputRequiresAnAbsoluteStateDir(t *testing.T) {
	config := validInput()
	config["state_dir"] = "relative/tsnet"

	_, err := readInput(encode(t, config))
	if err == nil {
		t.Fatal("a relative state directory must be rejected")
	}
	if !strings.Contains(err.Error(), "absolute") {
		t.Errorf("the error should explain the requirement, got %v", err)
	}
}

// Garbage on stdin is a parent-process bug, and saying so plainly is better
// than a nil-field failure further along.
func TestReadInputRejectsMalformedJSON(t *testing.T) {
	if _, err := readInput(strings.NewReader("{not json")); err == nil {
		t.Fatal("malformed JSON must be rejected")
	}
}

// The server name is optional because the shim defaults it to the upstream
// host, which is what a deployment normally wants.
func TestReadInputAcceptsAMissingServerName(t *testing.T) {
	config := validInput()
	delete(config, "headscale_server_name")

	if _, err := readInput(encode(t, config)); err != nil {
		t.Fatalf("the server name must be optional: %v", err)
	}
}

// Electron waits for exactly one JSON line on stdout to know the tailnet is
// up. Anything else - extra lines, no newline - would leave it waiting or
// parsing a partial value.
func TestAnnounceWritesOneJSONLine(t *testing.T) {
	var out bytes.Buffer
	message := ready{
		SocksAddr:     "127.0.0.1:41234",
		SocksUsername: "tsnet",
		SocksPassword: "deadbeef",
		TailnetIPs:    []string{"100.64.0.2"},
		ControlURL:    "http://127.0.0.1:41233",
	}

	if err := announce(&out, message); err != nil {
		t.Fatalf("announce must succeed: %v", err)
	}

	text := out.String()
	if !strings.HasSuffix(text, "\n") {
		t.Error("the readiness line must be newline-terminated so the parent can read it as a line")
	}
	if strings.Count(strings.TrimSuffix(text, "\n"), "\n") != 0 {
		t.Errorf("readiness must be a single line, got %q", text)
	}

	var decoded ready
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		t.Fatalf("the readiness line must be valid JSON: %v", err)
	}
	if decoded.SocksAddr != message.SocksAddr || decoded.SocksPassword != message.SocksPassword {
		t.Errorf("the SOCKS5 details must survive the round trip, got %+v", decoded)
	}
}

// The SOCKS5 username is fixed by tsnet rather than chosen by us. Hardcoding
// the wrong one would make every proxied connection fail authentication.
func TestSocksUsernameMatchesTsnet(t *testing.T) {
	if socksUsername != "tsnet" {
		t.Errorf("tsnet's loopback proxy authenticates as \"tsnet\", not %q", socksUsername)
	}
}
