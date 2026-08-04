package manifest

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// MockManifest is a mock implementation of the Manifest interface
type MockManifest struct {
	ID string
}

func (m *MockManifest) ManifestID() string {
	return m.ID
}

func TestStructName(t *testing.T) {
	mockManifest := &MockManifest{}
	assert.Equal(t, "MockManifest", StructName(mockManifest))
}
