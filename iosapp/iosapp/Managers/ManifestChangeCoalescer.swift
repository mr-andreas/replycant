import Foundation
import GitDB

// Merges a burst of manifest writes so the timeline refreshes once per
// burst instead of once per photo. Each refresh re-counts the library
// on the main actor while an upload is committing.
struct ManifestChangeCoalescer {
    private var pending: ManifestDatabaseChange?

    // Folds one database event into the pending burst. A full replace
    // already rebuilds the timeline, so earlier partial edits are dropped.
    mutating func ingest(_ change: ManifestDatabaseChange) {
        switch change {
        case .fullReplace:
            pending = .fullReplace
        case .incremental(let mutation):
            switch pending {
            case .fullReplace:
                return
            case .none:
                pending = .incremental(mutation)
            case .incremental(let existing):
                pending = .incremental(merge(existing, mutation))
            }
        }
    }

    // Returns the merged burst and clears it, so a second drain is a no-op
    // until another event arrives.
    mutating func drain() -> ManifestDatabaseChange? {
        defer { pending = nil }
        return pending
    }

    // Collapses two incremental writes of the same manifest into the later
    // one. Keeping both would shift the sparse timeline offset twice.
    private func merge(_ earlier: ManifestMutation, _ later: ManifestMutation) -> ManifestMutation {
        var added = earlier.added
        var updated = earlier.updated
        var removed = earlier.removed

        for manifest in later.added {
            let key = Identity(manifest)
            added.removeAll { Identity($0) == key }
            updated.removeAll { Identity($0) == key }
            removed.removeAll { Identity($0) == key }
            added.append(manifest)
        }
        for manifest in later.updated {
            let key = Identity(manifest)
            if let index = added.firstIndex(where: { Identity($0) == key }) {
                added[index] = manifest
            } else {
                updated.removeAll { Identity($0) == key }
                updated.append(manifest)
            }
        }
        for manifest in later.removed {
            let key = Identity(manifest)
            added.removeAll { Identity($0) == key }
            updated.removeAll { Identity($0) == key }
            removed.removeAll { Identity($0) == key }
            removed.append(manifest)
        }
        return ManifestMutation(added: added, updated: updated, removed: removed)
    }

    // Distinguishes manifests that share an id across kinds, so a thumbnail
    // and its original are not treated as the same row.
    private struct Identity: Equatable {
        let kind: String
        let id: String

        init(_ manifest: any Manifest) {
            kind = manifest.kindValue
            id = manifest.id
        }
    }
}
