package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSanitizeDeviceName verifies user input normalization keeps stable, portable identity labels.
func TestSanitizeDeviceName(t *testing.T) {
	t.Parallel()
	tests := []struct {
		in   string
		want string
	}{
		{in: "", want: defaultDeviceName},
		{in: "  ", want: defaultDeviceName},
		{in: "My Device", want: "my-device"},
		{in: "a@b#c", want: "abc"},
		{in: "a  --  b", want: "a-b"},
		{in: "--foo--", want: "foo"},
		{in: "my_device", want: "my_device"},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.in, func(t *testing.T) {
			t.Parallel()
			assert.Equal(t, tt.want, sanitizeDeviceName(tt.in))
		})
	}
}

// TestNewUUID verifies generated UUIDs remain RFC4122-compatible and non-repeating.
func TestNewUUID(t *testing.T) {
	t.Parallel()
	re := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	a := newUUID()
	b := newUUID()
	assert.Regexp(t, re, a)
	assert.Regexp(t, re, b)
	assert.NotEqual(t, a, b)
}

// TestValidateIdentity confirms malformed persisted identity data is rejected early.
func TestValidateIdentity(t *testing.T) {
	t.Parallel()
	key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
	valid := gitcrypt.Identity{
		AgePrivateKeyBase64: key,
		AgePublicKey:        "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
		DeviceName:          "dev",
		DeviceUUID:          "uuid",
		PublicKeySSH:        "ecdsa-sha2-nistp256 abc",
	}
	require.NoError(t, validateIdentity(valid))

	tests := []struct {
		name string
		mut  func(gitcrypt.Identity) gitcrypt.Identity
	}{
		{name: "missing age private", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.AgePrivateKeyBase64 = ""; return i }},
		{name: "invalid base64", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.AgePrivateKeyBase64 = "!!!!"; return i }},
		{name: "wrong length", mut: func(i gitcrypt.Identity) gitcrypt.Identity {
			i.AgePrivateKeyBase64 = base64.StdEncoding.EncodeToString([]byte("short"))
			return i
		}},
		{name: "missing age pub", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.AgePublicKey = ""; return i }},
		{name: "missing ssh", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.PublicKeySSH = ""; return i }},
		{name: "missing device name", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.DeviceName = ""; return i }},
		{name: "missing device uuid", mut: func(i gitcrypt.Identity) gitcrypt.Identity { i.DeviceUUID = ""; return i }},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := validateIdentity(tt.mut(valid))
			require.Error(t, err)
		})
	}
}

// TestCreateIdentityWithMTLS validates generated onboarding credentials are structurally valid.
func TestCreateIdentityWithMTLS(t *testing.T) {
	t.Parallel()
	identity, keyPEM, certPEM, err := gitcrypt.CreateIdentityWithMTLS("")
	require.NoError(t, err)

	assert.Equal(t, defaultDeviceName, identity.DeviceName)
	assert.NotEmpty(t, identity.DeviceUUID)
	assert.True(t, strings.HasPrefix(identity.AgePublicKey, "age1"))
	assert.True(t, strings.HasPrefix(identity.PublicKeySSH, "ecdsa-sha2-nistp256 "))

	keyBlock, _ := pem.Decode(keyPEM)
	require.NotNil(t, keyBlock)
	_, err = x509.ParseECPrivateKey(keyBlock.Bytes)
	require.NoError(t, err)

	certBlock, _ := pem.Decode(certPEM)
	require.NotNil(t, certBlock)
	cert, err := x509.ParseCertificate(certBlock.Bytes)
	require.NoError(t, err)
	assert.Equal(t, defaultDeviceName, cert.Subject.CommonName)
}

// TestFormatSSHPublicKey ensures SSH public key formatting stays compatible with gitd authorization.
func TestFormatSSHPublicKey(t *testing.T) {
	t.Parallel()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	withComment, err := gitcrypt.FormatSSHPublicKey(&priv.PublicKey, "my-device")
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(withComment, "ecdsa-sha2-nistp256 "))
	assert.True(t, strings.HasSuffix(withComment, " my-device"))

	withoutComment, err := gitcrypt.FormatSSHPublicKey(&priv.PublicKey, "")
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(withoutComment, "ecdsa-sha2-nistp256 "))
	assert.False(t, strings.HasSuffix(withoutComment, " "))
}

// TestBuildPublicKeyQrPayload verifies QR payload keys match iOS onboarding contract expectations.
func TestBuildPublicKeyQrPayload(t *testing.T) {
	t.Parallel()
	identity := gitcrypt.Identity{
		PublicKeySSH: "ssh",
		AgePublicKey: "age",
		DeviceName:   "name",
		DeviceUUID:   "uuid",
	}
	raw, err := gitcrypt.BuildPublicKeyQrPayload(identity, "caf00d")
	require.NoError(t, err)

	var payload map[string]string
	require.NoError(t, json.Unmarshal([]byte(raw), &payload))
	assert.Equal(t, "ssh", payload["pubkey"])
	assert.Equal(t, "age", payload["age_pubkey"])
	assert.Equal(t, "name", payload["name"])
	assert.Equal(t, "uuid", payload["uuid"])
	assert.Equal(t, "caf00d", payload["ca_hash"])
}

// TestEnsureFileExists validates path checks detect both missing files and directory misuse.
func TestEnsureFileExists(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	filePath := filepath.Join(tmp, "ok")
	testWriteFile(t, filePath, []byte("x"), 0o644)
	require.NoError(t, ensureFileExists(filePath))

	err := ensureFileExists(filepath.Join(tmp, "missing"))
	require.Error(t, err)

	err = ensureFileExists(tmp)
	require.Error(t, err)
}

// TestEncodeAgePublicKey verifies bech32 recipient encoding shape.
func TestEncodeAgePublicKey(t *testing.T) {
	t.Parallel()
	out, err := gitcrypt.EncodeAgePublicKey([]byte("0123456789abcdef0123456789abcdef"))
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(out, "age1"))
}

// TestEnsureLocalIdentity verifies identity material is created once and reused on subsequent calls.
func TestEnsureLocalIdentity(t *testing.T) {
	repo := testInitRepo(t)

	local, created, err := gitcrypt.EnsureLocalIdentity(repo, "Test Device")
	require.NoError(t, err)
	assert.True(t, created)
	assert.FileExists(t, local.IdentityPath)
	assert.FileExists(t, local.ClientKeyPath)
	assert.FileExists(t, local.ClientCertPath)
	assert.Contains(t, local.ConfigDirectory, filepath.Join(".git", "replycant"))
	assert.NotContains(t, local.ConfigDirectory, ".config/replycant")
	require.NoError(t, validateIdentity(local.Identity))

	local2, created2, err := gitcrypt.EnsureLocalIdentity(repo, "ignored-name")
	require.NoError(t, err)
	assert.False(t, created2)
	assert.Equal(t, local.Identity.DeviceUUID, local2.Identity.DeviceUUID)
}

// TestLoadLocalIdentity verifies repository-scoped error messaging and successful reload.
func TestLoadLocalIdentity(t *testing.T) {
	repo := testInitRepo(t)
	_, err := gitcrypt.LoadLocalIdentity(repo)
	require.Error(t, err)
	assert.Contains(t, err.Error(), filepath.Join(".git", "replycant", "identity.json"))

	local, _, err := gitcrypt.EnsureLocalIdentity(repo, "test")
	require.NoError(t, err)
	loaded, err := gitcrypt.LoadLocalIdentity(repo)
	require.NoError(t, err)
	assert.Equal(t, local.Identity.DeviceUUID, loaded.Identity.DeviceUUID)
}

// TestIdentityIsPerRepo ensures identities are isolated between repositories.
func TestIdentityIsPerRepo(t *testing.T) {
	repoA := testInitRepo(t)
	repoB := testInitRepo(t)

	idA, _, err := gitcrypt.EnsureLocalIdentity(repoA, "a")
	require.NoError(t, err)
	idB, _, err := gitcrypt.EnsureLocalIdentity(repoB, "b")
	require.NoError(t, err)
	assert.NotEqual(t, idA.Identity.DeviceUUID, idB.Identity.DeviceUUID)
	assert.NotEqual(t, idA.ConfigDirectory, idB.ConfigDirectory)
}
