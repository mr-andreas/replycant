// Definition of manifest types
package manifest

import "reflect"

// Represents manifests that may be stored in the git database. Each object will
// be stored at {Package}/{TypeName}/{ID}.yaml
type Manifest interface {
	// Unique identifier for this object. For instance a GUID.
	ManifestID() string
}

// Returns the struct name of the manifest.
func StructName(m Manifest) string {
	if t := reflect.TypeOf(m); t.Kind() == reflect.Ptr {
		return t.Elem().Name()
	} else {
		return t.Name()
	}
}
