package gitcrypt

import (
	"encoding/base64"
	"testing"

	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/curve25519"
)

// TestSpaceFromPath reads the space from the folder, which is the only
// place a file's space is recorded.
func TestSpaceFromPath(t *testing.T) {
	t.Parallel()
	space, ok := SpaceFromPath("encryptionspaces/phone/manifests/a.yaml")
	require.True(t, ok)
	require.Equal(t, "phone", space)

	_, ok = SpaceFromPath("encryption/current")
	require.False(t, ok)
	_, ok = SpaceFromPath("encryptionspaces/phone")
	require.False(t, ok)
	_, ok = SpaceFromPath("encryptionspaces-old/phone/manifests/a.yaml")
	require.False(t, ok)
}

// TestPathKinds distinguishes manifests from binaries so filters and
// importers do not encrypt the key set that lives beside them.
func TestPathKinds(t *testing.T) {
	t.Parallel()
	require.True(t, IsManifestPath("encryptionspaces/phone/manifests/a.yaml"))
	require.True(t, IsBinaryPath("encryptionspaces/phone/binary/a"))
	require.False(t, IsBinaryPath("encryptionspaces/phone/manifests/a.yaml"))
	require.False(t, IsManifestPath("encryptionspaces/phone/encryption/current"))
	require.False(t, IsBinaryPath("binary/phone/a"))
}

// TestKeySetRoot follows the space only when that space has its own
// key set. Anything else, including a space without one, uses the
// global key set.
func TestKeySetRoot(t *testing.T) {
	t.Parallel()
	own := func(space string) bool { return space == "upload" }
	require.Equal(t, "encryption", KeySetRoot("encryptionspaces/phone/manifests/a.yaml", own))
	require.Equal(t, "encryptionspaces/upload/encryption", KeySetRoot("encryptionspaces/upload/binary/a", own))
	require.Equal(t, "encryption", KeySetRoot("notes/keep.txt", own))
}

// TestRecipientListResolution is the only access rule: a space is the
// library plus its own members. A bad list is refused rather than
// treated as nobody.
func TestRecipientListResolution(t *testing.T) {
	t.Parallel()
	global, err := ParseRecipientList([]byte("members:\n  - phone\n  - backup\n"))
	require.NoError(t, err)
	require.Equal(t, []string{"phone", "backup"}, global.Members)

	space, err := ParseRecipientList([]byte("members:\n  - uploader\n"))
	require.NoError(t, err)
	empty, err := ParseRecipientList([]byte("{}\n"))
	require.NoError(t, err)
	require.Empty(t, empty.Members)

	known := map[string]struct{}{"phone": {}, "backup": {}, "uploader": {}}
	got, err := ResolveRecipients(global.Members, space.Members, known)
	require.NoError(t, err)
	require.Equal(t, []string{"phone", "backup", "uploader"}, got)

	got, err = ResolveRecipients(global.Members, nil, known)
	require.NoError(t, err)
	require.Equal(t, []string{"phone", "backup"}, got)

	_, err = ParseRecipientList([]byte("policy: library\nmembers:\n  - phone\n"))
	require.Error(t, err)
	_, err = ParseRecipientList([]byte("members:\n  - phone\n  - phone\n"))
	require.Error(t, err)
	_, err = ParseRecipientList([]byte("members:\n  - Phone\n"))
	require.Error(t, err)
	_, err = ResolveRecipients(global.Members, []string{"missing"}, known)
	require.Error(t, err)
	_, err = ResolveRecipients(nil, nil, known)
	require.Error(t, err)
}

// TestBuildFirstSpaceEpoch lets a creator publish a space without
// holding any existing KEK. The epoch opens for a listed recipient.
func TestBuildFirstSpaceEpoch(t *testing.T) {
	t.Parallel()
	priv := bytes32(t, 3)
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	require.NoError(t, err)
	agePub := mustAgePublic(t, pub)

	kek, files, err := BuildFirstSpaceEpoch([]string{"uploader"}, []string{agePub})
	require.NoError(t, err)
	require.Len(t, kek, 32)
	require.Equal(t, "1\n", string(files["current"]))

	parsed, err := ParseRecipientList(files["recipients.yaml"])
	require.NoError(t, err)
	require.Equal(t, []string{"uploader"}, parsed.Members)

	opened, err := UnwrapKEKFromAgeEnvelope(files["epochs/1.age"], base64.StdEncoding.EncodeToString(priv))
	require.NoError(t, err)
	require.Equal(t, kek, opened)
}

func bytes32(t *testing.T, seed byte) []byte {
	t.Helper()
	out := make([]byte, 32)
	for i := range out {
		out[i] = seed + byte(i)
	}
	return out
}

func mustAgePublic(t *testing.T, raw []byte) string {
	t.Helper()
	converted, err := bech32.ConvertBits(raw, 8, 5, true)
	require.NoError(t, err)
	encoded, err := bech32.Encode("age", converted)
	require.NoError(t, err)
	return encoded
}
