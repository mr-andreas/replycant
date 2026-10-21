import Foundation
import GitDB
import Testing
@testable import iosapp

// Covers burst merging without a timeline or a clock. The timeline applies
// one drained value, so a duplicate add or an add cancelled by a remove
// must already be one mutation.
struct ManifestChangeCoalescerTests {
    private func makeOriginal(id: String, sha256: String) -> OriginalManifest {
        let takenAt = Date(timeIntervalSince1970: 10)
        return OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: sha256,
            path: "/tmp/\(id).jpg",
            filesize: 1024,
            name: id,
            deviceSpace: "device-a",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            takenAt: takenAt,
            guessedTakenAt: takenAt
        )
    }

    @Test func fullReplaceSupersedesBufferedIncrementalChanges() {
        var coalescer = ManifestChangeCoalescer()
        coalescer.ingest(
            .incremental(
                ManifestMutation(
                    added: [makeOriginal(id: "a", sha256: "sha-a")],
                    updated: [],
                    removed: []
                )
            )
        )
        coalescer.ingest(.fullReplace)

        guard case .fullReplace = coalescer.drain() else {
            Issue.record("expected a full replace")
            return
        }
        #expect(coalescer.drain() == nil)
    }

    @Test func incrementalChangesMergeAndDedupeAdded() {
        var coalescer = ManifestChangeCoalescer()
        coalescer.ingest(
            .incremental(
                ManifestMutation(
                    added: [makeOriginal(id: "a", sha256: "sha-old")],
                    updated: [],
                    removed: []
                )
            )
        )
        coalescer.ingest(
            .incremental(
                ManifestMutation(
                    added: [
                        makeOriginal(id: "a", sha256: "sha-new"),
                        makeOriginal(id: "b", sha256: "sha-b"),
                    ],
                    updated: [],
                    removed: []
                )
            )
        )

        guard case .incremental(let mutation) = coalescer.drain() else {
            Issue.record("expected one incremental mutation")
            return
        }
        #expect(mutation.added.map(\.id) == ["a", "b"])
        let originals = mutation.added.compactMap { $0 as? OriginalManifest }
        #expect(originals.first?.spec.sha256 == "sha-new")
        #expect(coalescer.drain() == nil)
    }

    @Test func addedThenRemovedNetsToRemovedOnly() {
        var coalescer = ManifestChangeCoalescer()
        let original = makeOriginal(id: "a", sha256: "sha-a")
        coalescer.ingest(
            .incremental(ManifestMutation(added: [original], updated: [], removed: []))
        )
        coalescer.ingest(
            .incremental(ManifestMutation(added: [], updated: [], removed: [original]))
        )

        guard case .incremental(let mutation) = coalescer.drain() else {
            Issue.record("expected one incremental mutation")
            return
        }
        #expect(mutation.added.isEmpty)
        #expect(mutation.removed.map(\.id) == ["a"])
    }

    @Test func drainIsNilWhenNothingIsBuffered() {
        var coalescer = ManifestChangeCoalescer()
        #expect(coalescer.drain() == nil)
    }
}
