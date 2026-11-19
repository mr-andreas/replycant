package migrate

import (
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/keyset"
	"github.com/stretchr/testify/require"
)

// TestEncryptionSpacesStepMovesTreesWithoutChangingBytes keeps every
// encrypted object valid. The server does not hold the KEK, so the
// step may only rename.
func TestEncryptionSpacesStepMovesTreesWithoutChangingBytes(t *testing.T) {
	t.Parallel()
	body := mustKeySet(t, "phone")
	repo, dir := initRepo(t)
	commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version":      "2\n",
		"pubkeys/phone.yaml": body,
		"manifests/phone/media.replycant.com/v1alpha1/Original/a.yaml": "cipher-a",
		"binary/phone/media.replycant.com/v1alpha1/Original/a":         "pointer-a",
		"notes/keep.txt": "keep",
	})

	result, err := Run(dir)
	require.NoError(t, err)
	require.Equal(t, Result{Migrated: true, From: 2, To: 3}, result)
	require.Equal(t, "cipher-a", readBlob(t, dir, "encryptionspaces/phone/manifests/media.replycant.com/v1alpha1/Original/a.yaml"))
	require.Equal(t, "pointer-a", readBlob(t, dir, "encryptionspaces/phone/binary/media.replycant.com/v1alpha1/Original/a"))
	require.Equal(t, "keep", readBlob(t, dir, "notes/keep.txt"))
	require.NotContains(t, fileNames(t, dir), "manifests/phone/media.replycant.com/v1alpha1/Original/a.yaml")

	parsed, err := gitcrypt.ParseRecipientList([]byte(readBlob(t, dir, "encryption/recipients.yaml")))
	require.NoError(t, err)
	require.Equal(t, []string{"phone"}, parsed.Members)
}

// TestVersion1ReachesEncryptionSpacesInOneCommit checks a library that
// still has loose public keys. Clients must not observe the key-set
// layout without the new folders.
func TestVersion1ReachesEncryptionSpacesInOneCommit(t *testing.T) {
	t.Parallel()
	ssh, age, _ := mustMaterial(t, "phone")
	repo, dir := initRepo(t)
	commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version":          "1\n",
		"pubkeys/phone.pub":      ssh + "\n",
		"pubkeys/phone.age":      age + "\n",
		"manifests/phone/a.yaml": "cipher",
	})

	result, err := Run(dir)
	require.NoError(t, err)
	require.Equal(t, Result{Migrated: true, From: 1, To: 3}, result)
	require.Equal(t, "cipher", readBlob(t, dir, "encryptionspaces/phone/manifests/a.yaml"))
	parsed, err := gitcrypt.ParseRecipientList([]byte(readBlob(t, dir, "encryption/recipients.yaml")))
	require.NoError(t, err)
	require.Equal(t, []string{"phone"}, parsed.Members)
	require.Equal(t, 2, commitCount(t, dir))
}

// TestEncryptionSpacesStepRefusesAPartialLayout leaves main where it
// was. Publishing a half-moved tree would make every client refuse
// the library.
func TestEncryptionSpacesStepRefusesAPartialLayout(t *testing.T) {
	t.Parallel()
	body := mustKeySet(t, "phone")
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{
			name: "stray manifest",
			files: map[string]string{
				"gitdb/version":        "2\n",
				"pubkeys/phone.yaml":   body,
				"manifests/loose.yaml": "x",
			},
			want: "manifests/",
		},
		{
			name: "stray binary",
			files: map[string]string{
				"gitdb/version":      "2\n",
				"pubkeys/phone.yaml": body,
				"binary/loose":       "x",
			},
			want: "binary/",
		},
		{
			name: "encryption spaces exist",
			files: map[string]string{
				"gitdb/version":                           "2\n",
				"pubkeys/phone.yaml":                      body,
				"encryptionspaces/phone/manifests/a.yaml": "x",
			},
			want: "encryptionspaces/",
		},
		{
			name: "recipients exist",
			files: map[string]string{
				"gitdb/version":              "2\n",
				"pubkeys/phone.yaml":         body,
				"encryption/recipients.yaml": "members: []\n",
			},
			want: "recipients.yaml",
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

// TestCurrentVersion3DoesNothing keeps a library that is already on
// the pin from being rewritten on the next boot.
func TestCurrentVersion3DoesNothing(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	seed := commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version": "3\n",
	})
	result, err := Run(dir)
	require.NoError(t, err)
	require.False(t, result.Migrated)
	require.Equal(t, seed, headCommit(t, dir).Hash)
}

func mustKeySet(t *testing.T, name string) string {
	t.Helper()
	ssh, age, _ := mustMaterial(t, name)
	body, err := keyset.Marshal(keyset.KeySet{
		APIVersion: keyset.APIVersion,
		Kind:       keyset.Kind,
		Metadata:   keyset.Metadata{Name: name},
		Spec: keyset.Spec{
			Type:          keyset.TypeDevice,
			MTLSPublicKey: ssh,
			AgePublicKey:  age,
		},
	})
	require.NoError(t, err)
	return string(body)
}
