package gitcrypt

import (
	"encoding/pem"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The CA whose derivation three independent implementations have to agree on.
//
// Shared verbatim with tunnel.TestLabelMatchesClientDerivation in the
// replycant-server repository. A device dials the hostname, the compose stack
// issues a certificate for it, and the relay authorizes a registration under
// it; any disagreement strands a deployment with no diagnostic beyond "cannot
// connect".
const crossRepoFixtureCAPEM = `-----BEGIN CERTIFICATE-----
MIIBQjCB6KADAgECAgEqMAoGCCqGSM49BAMCMBYxFDASBgNVBAMTC3JlcGx5Y2Fu
dC1jYTAeFw0yNjA0MjAwMDAwMDBaFw0yNzA0MjAwMDAwMDBaMBYxFDASBgNVBAMT
C3JlcGx5Y2FudC1jYTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBe9qUrj9U7h
N+BlYbM2Q09qfB5cj3GmL9j6x2/pRjYKf0Qm2YpP53rUEfCYyYJ3r8uWPtTGC4+E
vR5jS6wS7W6jEzARMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIg
LEj+/WUkDhfmrCRf4r0cNwQ/2M0wXWJmZSp+2FwsKscCIQDKQ2nEAj+8DkOn2h0o
0fJxQzN9Mn5JgKaYz4cK2vW8mA==
-----END CERTIFICATE-----`

// The expected derivation for that fixture, written out rather than computed.
//
// Computing it here would only prove the code agrees with itself. These
// literals are what the other two implementations are checked against, so a
// change to the derivation has to be a deliberate edit of a value that appears
// in two repositories.
const (
	crossRepoFixtureLabel = "c09d6ac6abbf7d3cd7a726c2e02efa98"
	crossRepoFixtureShard = "s52"
)

// Pins the derivation both clients and the relay depend on.
func TestFixtureCADerivesTheExpectedHostname(t *testing.T) {
	t.Parallel()

	label, err := CADNSLabel(crossRepoFixtureCAPEM)
	require.NoError(t, err)
	assert.Equal(t, crossRepoFixtureLabel, label)

	slot, err := CATunnelSlot(crossRepoFixtureCAPEM)
	require.NoError(t, err)
	assert.Equal(t, crossRepoFixtureShard, TunnelShardLabel(slot))

	host, err := CATunnelHost(crossRepoFixtureCAPEM, "tunnel.replycant.com")
	require.NoError(t, err)
	assert.Equal(t,
		crossRepoFixtureLabel+"."+crossRepoFixtureShard+".tunnel.replycant.com", host)
}

// The compose stack derives the same hostname in shell, because server-key has
// to issue the hsproxy certificate before any Go code with the CA in hand
// runs. Two implementations of one derivation is a drift risk, so the shell is
// executed here against the same fixture rather than reviewed by eye.
//
// Reads the snippet out of docker-compose.yaml rather than copying it, since a
// copy would keep passing while the deployed derivation changed.
func TestComposeDerivesTheSameHostnameInShell(t *testing.T) {
	t.Parallel()

	compose, err := os.ReadFile("../../docker-compose.yaml")
	require.NoError(t, err)

	// The heredoc body is indented by the YAML block scalar; shell does not
	// care, and leaving it in place keeps the assertion honest about what runs.
	snippet := regexp.MustCompile(`(?s)CA_LABEL=\$\$\(echo.*?CA_SHARD=[^\n]*\n`).
		Find(compose)
	require.NotNil(t, snippet, "server-key must derive CA_LABEL and CA_SHARD")

	block, _ := pem.Decode([]byte(crossRepoFixtureCAPEM))
	require.NotNil(t, block)

	// Compose doubles dollars so the container's shell sees single ones. The
	// digest is injected instead of running the openssl pipeline, so the test
	// does not depend on the local openssl build accepting the fixture.
	script := strings.ReplaceAll(string(snippet), "$$", "$")
	script = regexp.MustCompile(`CA_DIGEST=[^\n]*\n?`).ReplaceAllLiteralString(script, "")
	script = "CA_DIGEST=" + fullDigestHex(t, block.Bytes) + "\n" + script +
		"\nprintf '%s %s' \"$CA_LABEL\" \"$CA_SHARD\"\n"

	output, err := exec.Command("/bin/sh", "-ec", script).Output()
	require.NoError(t, err, "the compose derivation must run under a POSIX shell")

	assert.Equal(t, crossRepoFixtureLabel+" "+crossRepoFixtureShard, string(output),
		"the shell derivation must match the Go one")
}

func fullDigestHex(t *testing.T, der []byte) string {
	t.Helper()
	hash, err := ComputeCAHash(string(pem.EncodeToMemory(&pem.Block{
		Type: "CERTIFICATE", Bytes: der,
	})))
	require.NoError(t, err)
	return hash
}
