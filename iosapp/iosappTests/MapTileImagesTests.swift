import Testing
import UIKit
@testable import iosapp

// A reused map annotation must show the photo for the cluster it
// currently represents. These tests pin images to the item id they were
// loaded for, which is what keeps a recycled tile from keeping a
// previous place's photo.
@MainActor
struct MapTileImagesTests {
    @Test func storesEachImageUnderTheItemItWasLoadedFor() async throws {
        let bench = UIImage()
        let stage = UIImage()
        let byId = ["bench": bench, "stage": stage]
        let store = MapTileImages { item in
            byId[item.id]
        }

        store.load([Self.item("bench"), Self.item("stage")])

        try await Self.waitUntil {
            store.images["bench"] != nil && store.images["stage"] != nil
        }
        #expect(store.images["bench"] === bench)
        #expect(store.images["stage"] === stage)
    }

    // A second request for a tile that is already loading, or already
    // has a photo, must not start another download. Panning back over
    // the same place is the common case.
    @Test func doesNotStartAnotherLoadWhileOneIsInFlightOrAlreadyStored() async throws {
        let probe = LoadProbe()
        let store = MapTileImages { item in
            await probe.begin(item.id)
        }
        let item = Self.item("bench")

        store.load([item])
        try await Self.waitUntil { probe.calls("bench") == 1 }

        store.load([item])
        #expect(probe.calls("bench") == 1)

        probe.finish("bench", image: UIImage())
        try await Self.waitUntil { store.images["bench"] != nil }

        store.load([item])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(probe.calls("bench") == 1)
    }

    private static func item(_ id: String) -> TimelineItem {
        TimelineItem(original: OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: "sha-\(id)",
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
            takenAt: Date(timeIntervalSince1970: 200),
            guessedTakenAt: Date(timeIntervalSince1970: 200)
        ))
    }

    private static func waitUntil(
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for tile images")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// Holds a tile load open so a test can call load again before the first
// one finishes, which is when a duplicate download would start.
@MainActor
private final class LoadProbe {
    private var callCounts: [String: Int] = [:]
    private var waiting: [String: CheckedContinuation<UIImage?, Never>] = [:]

    func calls(_ id: String) -> Int {
        callCounts[id, default: 0]
    }

    func begin(_ id: String) async -> UIImage? {
        callCounts[id, default: 0] += 1
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
        }
    }

    func finish(_ id: String, image: UIImage?) {
        waiting.removeValue(forKey: id)?.resume(returning: image)
    }
}
