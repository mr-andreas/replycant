package manifest

import (
	"reflect"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRegistry_Unmarshal(t *testing.T) {
	registry := NewRegistry()
	registry.Register("github.com/mr-andreas/replycant/server/manifest", &MockManifest{})

	yaml := "id: validID"
	path := "github.com/mr-andreas/replycant/server/manifest/MockManifest/va/li/dID.yaml"

	m, ti, err := registry.Unmarshal(path, strings.NewReader(yaml))
	require.NoError(t, err)
	assert.Equal(t, "validID", m.ManifestID())

	// Verify returned RegistryType
	expectedTypeInfo := &RegisteredType{
		Type:              reflect.TypeOf(&MockManifest{}),
		RegisteredPackage: "github.com/mr-andreas/replycant/server/manifest",
		StructName:        "MockManifest",
		reflectedName:     "github.com/mr-andreas/replycant/server/manifest.MockManifest",
	}
	assert.Equal(t, expectedTypeInfo, ti)
}

func TestRegistry_Unmarshal_Errors(t *testing.T) {
	registry := NewRegistry()
	registry.Register("github.com/mr-andreas/replycant/server/manifest", &MockManifest{})

	validYAML := "id: validID"
	validPath := "github.com/mr-andreas/replycant/server/manifest/MockManifest/va/li/dID.yaml"
	invalidTypePath := "InvalidManifestType/va/li/dID.yaml"
	idMismatchPath := "github.com/mr-andreas/replycant/server/manifest/MockManifest/in/va/lidID.yaml"
	invalidYAML := ":-"
	pathWithoutYAMLExtension := "github.com/mr-andreas/replycant/server/manifest/MockManifest/no/YA/MLExtension"

	tests := []struct {
		name        string
		path        string
		yaml        string
		expectedErr error
	}{
		{"InvalidType", invalidTypePath, validYAML, ErrUnregisteredType},
		{"IDMismatch", idMismatchPath, validYAML, ErrIDMismatch},
		{"InvalidYAML", validPath, invalidYAML, ErrUnmarshalFailed},
		{"NoYAMLExtension", pathWithoutYAMLExtension, validYAML, ErrUnmarhsalWithoutYAMLExtension},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := registry.Unmarshal(tt.path, strings.NewReader(tt.yaml))
			assert.ErrorIs(t, err, tt.expectedErr)
		})
	}
}

func TestRegistry_Marshal(t *testing.T) {
	registry := NewRegistry()
	registry.Register("github.com/mr-andreas/replycant/server/manifest", &MockManifest{})

	m := &MockManifest{ID: "validID"}

	path, yaml, err := registry.Marshal(m)
	assert.NoError(t, err)
	assert.Equal(t, "id: validID\n", string(yaml))
	assert.Equal(t, "github.com/mr-andreas/replycant/server/manifest/MockManifest/va/li/dID.yaml", path)
}

func TestRegistry_Marshal_Errors(t *testing.T) {
	registry := NewRegistry()

	m := &MockManifest{ID: "id"}
	_, _, err := registry.Marshal(m)
	assert.ErrorIs(t, err, ErrUnregisteredType)
}

func TestRegistry_Register(t *testing.T) {
	registry := NewRegistry()
	packageName := "github.com/mr-andreas/replycant/server/manifest"
	manifest := &MockManifest{}

	registry.Register(packageName, manifest)

	rt := registry.byRegisteredName[packageName+"/MockManifest"]
	if rt.Type != reflect.TypeOf(manifest) {
		t.Errorf("Expected registered type to be %v, but got %v", reflect.TypeOf(manifest), rt.Type)
	}

	if rt.RegisteredName() != packageName+"/MockManifest" {
		t.Errorf("Expected registered name to be %s, but got %s", packageName+"/MockManifest", rt.RegisteredName())
	}

	if rt.reflectedName != "github.com/mr-andreas/replycant/server/manifest.MockManifest" {
		t.Errorf("Expected reflected name to be %s, but got %s", "github.com/mr-andreas/replycant/server/manifest.MockManifest", rt.reflectedName)
	}
}

func TestNewRegistryType(t *testing.T) {
	packageName := "github.com/mr-andreas/replycant/server/manifest"
	manifest := &MockManifest{}

	rt := newRegistryType(packageName, manifest)

	expectedTyp := reflect.TypeOf(manifest)
	if rt.Type != expectedTyp {
		t.Errorf("Expected registered type to be %v, but got %v", expectedTyp, rt.Type)
	}

	expectedRegisteredName := packageName + "/MockManifest"
	if rt.RegisteredName() != expectedRegisteredName {
		t.Errorf("Expected registered name to be %s, but got %s", expectedRegisteredName, rt.RegisteredName())
	}

	expectedReflectedName := "github.com/mr-andreas/replycant/server/manifest.MockManifest"
	if rt.reflectedName != expectedReflectedName {
		t.Errorf("Expected reflected name to be %s, but got %s", expectedReflectedName, rt.reflectedName)
	}
}

func TestRegistry_TypeInfo(t *testing.T) {
	registry := NewRegistry()
	packageName := "github.com/mr-andreas/replycant/server/manifest"
	manifest := &MockManifest{}
	registry.Register(packageName, manifest)

	expectedTypeInfo := &RegisteredType{
		Type:              reflect.TypeOf(manifest),
		RegisteredPackage: packageName,
		StructName:        "MockManifest",
		reflectedName:     "github.com/mr-andreas/replycant/server/manifest.MockManifest",
	}

	typeInfo, err := registry.TypeInfo(manifest)
	assert.NoError(t, err)
	assert.Equal(t, expectedTypeInfo, typeInfo)
}

func TestRegistry_TypeInfo_Error(t *testing.T) {
	registry := NewRegistry()
	manifest := &MockManifest{}

	_, err := registry.TypeInfo(manifest)
	assert.ErrorIs(t, err, ErrUnregisteredType)
}
