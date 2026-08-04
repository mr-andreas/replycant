package manifest

import (
	"fmt"
	"io"
	"path"
	"reflect"
	"strings"

	"gopkg.in/yaml.v3"
)

var (
	ErrIDMismatch                    = fmt.Errorf("id in manifest does not match filename")
	ErrUnregisteredType              = fmt.Errorf("unknown manifest type")
	ErrUnmarshalFailed               = fmt.Errorf("failed to unmarshal manifest")
	ErrUnmarhsalWithoutYAMLExtension = fmt.Errorf("path does not have a .yaml extension")
)

type RegisteredType struct {
	// The regsitered type
	Type reflect.Type

	// Package this type was registered at, such as
	// "github.com/mr-andreas/replycant/server/manifest"
	RegisteredPackage string

	// The name of the struct, such as "MyManifest"
	StructName string

	// The full name of the type as it was reflected, such as
	// "github.com/mr-andreas/replycant/server/manifest.MyManifest"
	reflectedName string
}

// Returns the name the type was registered under, such as
// "github.com/mr-andreas/replycant/server/manifest/MyManifest"
func (rt *RegisteredType) RegisteredName() string {
	return rt.RegisteredPackage + "/" + rt.StructName
}

func reflectedName(m Manifest) string {
	typ := reflect.TypeOf(m)
	reflectedName := typ.PkgPath() + "." + typ.Name()
	if typ.Kind() == reflect.Ptr {
		t := typ.Elem()
		reflectedName = t.PkgPath() + "." + t.Name()
	}
	return reflectedName
}

func newRegistryType(packageName string, m Manifest) RegisteredType {
	return RegisteredType{
		Type:              reflect.TypeOf(m),
		RegisteredPackage: packageName,
		StructName:        StructName(m),
		reflectedName:     reflectedName(m),
	}
}

// A registry of all known manifest types.
type Registry struct {
	// Map of manifest type names to their respective manifest types.
	byRegisteredName map[string]RegisteredType
	byReflectedName  map[string]RegisteredType
}

// Creates a new registry.
func NewRegistry() *Registry {
	return &Registry{
		byRegisteredName: map[string]RegisteredType{},
		byReflectedName:  map[string]RegisteredType{},
	}
}

// Registers a manifest type with the registry. It will be available for
// serialization and deserialization.
func (r *Registry) Register(packageName string, m Manifest) {
	rt := newRegistryType(packageName, m)
	r.byRegisteredName[rt.RegisteredName()] = rt
	r.byReflectedName[rt.reflectedName] = rt
}

// Converts the manifest to YAML. If the manifest type is not registered, an
// error will be returned.
//
// The manifest will be stored in the format {FullTypeName}/{ID}.yaml
func (r *Registry) Marshal(m Manifest) (path string, yml []byte, _ error) {
	rt, ok := r.byReflectedName[reflectedName(m)]
	if !ok {
		return "", nil, fmt.Errorf("%w: %s", ErrUnregisteredType, reflectedName(m))
	}

	yml, err := yaml.Marshal(m)
	if err != nil {
		return "", nil, fmt.Errorf("marshal: %w", err)
	}

	return rt.RegisteredName() + "/" + shardName(m.ManifestID()) + ".yaml", yml, nil
}

// Loads a manifest from YAML. If the manifest type is not registered, an error
// will be returned.
//
// The "id" field in the manifest must be equal to the filename in Path.
func (r *Registry) Unmarshal(Path string, rd io.Reader) (Manifest, *RegisteredType, error) {
	// Verify that the path has a .yaml extension
	if path.Ext(Path) != ".yaml" {
		return nil, nil, fmt.Errorf("%w: %s", ErrUnmarhsalWithoutYAMLExtension, Path)
	}

	filename := path.Base(Path)
	stem := filename[:len(filename)-len(".yaml")]
	typeName := path.Dir(Path)
	idFromFile := stem

	// Support both unsharded {type}/{id}.yaml and sharded {type}/{xx}/{yy}/{rest}.yaml paths.
	ti, ok := r.byRegisteredName[typeName]
	if !ok {
		typeName = path.Dir(path.Dir(path.Dir(Path)))
		ti, ok = r.byRegisteredName[typeName]
		if !ok {
			return nil, nil, fmt.Errorf("%w: %s", ErrUnregisteredType, typeName)
		}
		idFromSharded, err := unshardFilename(Path)
		if err != nil {
			return nil, nil, err
		}
		idFromFile = idFromSharded
	}

	// Create a new instance of the manifest type
	var manifest Manifest
	if ti.Type.Kind() == reflect.Ptr {
		manifest = reflect.New(ti.Type.Elem()).Interface().(Manifest)
	} else {
		manifest = reflect.New(ti.Type).Interface().(Manifest)
	}

	// Decode the YAML data into the manifest
	dec := yaml.NewDecoder(rd)
	if err := dec.Decode(manifest); err != nil {
		return nil, nil, fmt.Errorf("%w: %s", ErrUnmarshalFailed, err)
	}

	// Verify that the ID in the manifest matches the filename-derived id.
	if manifest.ManifestID() != idFromFile {
		return nil, nil, fmt.Errorf("%w: %s", ErrIDMismatch, Path)
	}

	return manifest, &ti, nil
}

// shardName spreads one manifest id across two directories to keep git trees small.
func shardName(name string) string {
	if len(name) < 5 {
		return name
	}
	return name[:2] + "/" + name[2:4] + "/" + name[4:]
}

// unshardFilename reconstructs one manifest id from a sharded YAML path.
func unshardFilename(pathname string) (string, error) {
	filename := path.Base(pathname)
	if !strings.HasSuffix(filename, ".yaml") {
		return "", fmt.Errorf("%w: %s", ErrUnmarhsalWithoutYAMLExtension, pathname)
	}
	stem := filename[:len(filename)-len(".yaml")]
	shard2 := path.Base(path.Dir(pathname))
	shard1 := path.Base(path.Dir(path.Dir(pathname)))
	return shard1 + shard2 + stem, nil
}

// Returns type info for the given manifest. If the type is not registered,
// ErrUnregisteredType will be returned.
func (r *Registry) TypeInfo(m Manifest) (*RegisteredType, error) {
	rt, ok := r.byReflectedName[reflectedName(m)]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrUnregisteredType, reflectedName(m))
	}
	return &rt, nil
}
