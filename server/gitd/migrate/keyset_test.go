package migrate

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"testing"

	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/keyset"
	"github.com/mr-andreas/replycant/server/gitd/auth"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/curve25519"
)

// TestKeySetStepRewritesDeviceAndRecovery checks the v1 layout becomes
// one key set per holder, with the recovery suffix turned into a type
// instead of a second name.
func TestKeySetStepRewritesDeviceAndRecovery(t *testing.T) {
	t.Parallel()
	deviceSSH, deviceAge, deviceKey := mustMaterial(t, "phone")
	recoverySSH, recoveryAge, recoveryKey := mustMaterial(t, "backup")
	repo, dir := initRepo(t)
	commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version":                      "1\n",
		"notes/keep.txt":                     "keep",
		"pubkeys/iphone-16e.pub":             deviceSSH + "\n",
		"pubkeys/iphone-16e.age":             deviceAge + "\n",
		"pubkeys/backup-phrase.recovery.pub": recoverySSH + "\n",
		"pubkeys/backup-phrase.recovery.age": recoveryAge + "\n",
	})

	result, err := Run(dir)
	require.NoError(t, err)
	require.Equal(t, Result{Migrated: true, From: 1, To: 2}, result)
	require.Equal(t, "2\n", readBlob(t, dir, "gitdb/version"))
	require.Equal(t, "keep", readBlob(t, dir, "notes/keep.txt"))

	device := mustParseKeySet(t, readBlob(t, dir, "pubkeys/iphone-16e.yaml"))
	require.Equal(t, "iphone-16e", device.Metadata.Name)
	require.Equal(t, keyset.TypeDevice, device.Spec.Type)
	require.Equal(t, deviceSSH, device.Spec.MTLSPublicKey)
	require.Equal(t, deviceAge, device.Spec.AgePublicKey)
	require.Nil(t, device.Spec.DisplayName)

	recovery := mustParseKeySet(t, readBlob(t, dir, "pubkeys/backup-phrase.yaml"))
	require.Equal(t, "backup-phrase", recovery.Metadata.Name)
	require.Equal(t, keyset.TypeRecovery, recovery.Spec.Type)
	require.Equal(t, recoverySSH, recovery.Spec.MTLSPublicKey)
	require.Nil(t, recovery.Spec.DisplayName)

	names := fileNames(t, dir)
	require.NotContains(t, names, "pubkeys/iphone-16e.pub")
	require.NotContains(t, names, "pubkeys/iphone-16e.age")
	require.NotContains(t, names, "pubkeys/backup-phrase.recovery.pub")
	require.NotContains(t, names, "pubkeys/backup-phrase.recovery.age")

	// The tailnet reconciler fingerprints the key, not the filename.
	// A migration that re-encodes the point would expire every device.
	authorized, err := auth.ReadAuthorizedKeys(dir)
	require.NoError(t, err)
	require.Equal(t, auth.KeyFingerprint(deviceKey), auth.KeyFingerprint(authorized["iphone-16e"]))
	require.Equal(t, auth.KeyFingerprint(recoveryKey), auth.KeyFingerprint(authorized["backup-phrase"]))
}

// TestKeySetStepFailsClosed refuses to drop a key it cannot pair or
// parse. Dropping it would revoke that device with no commit to undo.
func TestKeySetStepFailsClosed(t *testing.T) {
	t.Parallel()
	ssh, age, _ := mustMaterial(t, "phone")
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{
			name: "orphan pub",
			files: map[string]string{
				"gitdb/version":      "1\n",
				"pubkeys/orphan.pub": ssh + "\n",
			},
			want: "pubkeys/orphan.pub",
		},
		{
			name: "orphan age",
			files: map[string]string{
				"gitdb/version":      "1\n",
				"pubkeys/orphan.age": age + "\n",
			},
			want: "pubkeys/orphan.age",
		},
		{
			name: "bad key",
			files: map[string]string{
				"gitdb/version":   "1\n",
				"pubkeys/bad.pub": "not-a-key\n",
				"pubkeys/bad.age": age + "\n",
			},
			want: "pubkeys/bad.pub",
		},
		{
			name: "invalid name",
			files: map[string]string{
				"gitdb/version":   "1\n",
				"pubkeys/Bad.pub": ssh + "\n",
				"pubkeys/Bad.age": age + "\n",
			},
			want: "pubkeys/Bad.pub",
		},
		{
			name: "unexpected file",
			files: map[string]string{
				"gitdb/version":     "1\n",
				"pubkeys/notes.txt": "hello\n",
			},
			want: "pubkeys/notes.txt",
		},
		{
			name: "nested file",
			files: map[string]string{
				"gitdb/version":            "1\n",
				"pubkeys/nested/phone.pub": ssh + "\n",
				"pubkeys/nested/phone.age": age + "\n",
			},
			want: "pubkeys/nested/",
		},
		{
			name: "name collision",
			files: map[string]string{
				"gitdb/version":            "1\n",
				"pubkeys/foo.pub":          ssh + "\n",
				"pubkeys/foo.age":          age + "\n",
				"pubkeys/foo.recovery.pub": ssh + "\n",
				"pubkeys/foo.recovery.age": age + "\n",
			},
			want: "foo",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			repo, dir := initRepo(t)
			seed := commitFiles(t, repo, dir, "seed", tc.files)
			_, err := Run(dir)
			require.ErrorContains(t, err, tc.want)
			require.Equal(t, seed, headCommit(t, dir).Hash)
		})
	}
}

func mustMaterial(t *testing.T, comment string) (string, string, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	ssh, err := gitcrypt.FormatSSHPublicKey(&key.PublicKey, comment)
	require.NoError(t, err)
	seed := make([]byte, 32)
	_, err = rand.Read(seed)
	require.NoError(t, err)
	raw, err := curve25519.X25519(seed, curve25519.Basepoint)
	require.NoError(t, err)
	age, err := gitcrypt.EncodeAgePublicKey(raw)
	require.NoError(t, err)
	return ssh, age, &key.PublicKey
}

func mustParseKeySet(t *testing.T, raw string) keyset.KeySet {
	t.Helper()
	parsed, err := keyset.Parse([]byte(raw))
	require.NoError(t, err)
	return parsed
}

func fileNames(t *testing.T, dir string) []string {
	t.Helper()
	commit := headCommit(t, dir)
	files, err := commit.Files()
	require.NoError(t, err)
	var names []string
	err = files.ForEach(func(file *object.File) error {
		names = append(names, file.Name)
		return nil
	})
	require.NoError(t, err)
	return names
}
