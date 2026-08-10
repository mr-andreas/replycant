package lfs

import (
	"sort"
)

// MissingObjects returns the OIDs that are absent from the on-disk store so the
// pre-receive hook can reject pushes that reference blobs not yet uploaded.
// Duplicate OIDs are checked once; results are sorted for stable error messages.
func MissingObjects(store *Store, objects []Object) []string {
	if store == nil || len(objects) == 0 {
		return nil
	}

	seen := map[string]struct{}{}
	missing := make([]string, 0)
	for _, obj := range objects {
		if obj.OID == "" {
			continue
		}
		if _, exists := seen[obj.OID]; exists {
			continue
		}
		seen[obj.OID] = struct{}{}
		if !store.Exists(obj.OID) {
			missing = append(missing, obj.OID)
		}
	}
	sort.Strings(missing)
	return missing
}
