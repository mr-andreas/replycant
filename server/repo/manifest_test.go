package repo

type testManifest struct {
	ID      string
	ANumber int
}

func (m *testManifest) ManifestPackage() string {
	return "github.com/mr-andreas/replycant/server/repo"
}

func (m *testManifest) ManifestID() string { return m.ID }

type testBigManifest struct {
	ID          string
	StringArray []string
}

func (m *testBigManifest) ManifestID() string { return m.ID }
