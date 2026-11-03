import Foundation
import GitDB
import Testing
@testable import iosapp

// The top cache is what makes the first screen instant after a
// charging wake. These tests pin the thumbnails that wake shares
// with the open timeline: the newest page, the 225px variant, and
// a stop between items when the wake is cancelled.
@Suite("Disk cache warming")
@MainActor
struct DiskCacheWarmingTests {
    @Test("Warming selects the newest originals and their 225px thumbnail")
    func testNewestPageUsesDisplayThumbnail() async {
        let older = original(id: "older", name: "older-photo", takenAt: 10)
        let middle = original(id: "middle", name: "middle-photo", takenAt: 20)
        let newer = original(id: "newer", name: "newer-photo", takenAt: 30)
        let newest = original(id: "newest", name: "newest-photo", takenAt: 40)
        let loader = MockManifestLoader()
        loader.setOriginals([newest, older, middle, newer])
        loader.setThumbnails([
            thumbnailSet(for: older, widths: [150, 225, 1024]),
            thumbnailSet(for: middle, widths: [150, 225, 1024]),
            thumbnailSet(for: newer, widths: [150, 225, 1024]),
            thumbnailSet(for: newest, widths: [150, 1024, 225]),
        ])

        let warmed = await warm(loader: loader, itemCount: 2)

        #expect(warmed.map(\.itemId) == ["newer", "newest"])
        #expect(warmed.map(\.lfsPath) == [
            thumbnailPath(name: "newer-photo-225"),
            thumbnailPath(name: "newest-photo-225"),
        ])
    }

    // A library that only has the small grid thumbnail still needs a
    // cached image. The largest available variant is the fallback.
    @Test("Warming uses the largest thumbnail when none is 225px or wider")
    func testFallsBackToLargestThumbnail() async {
        let only = original(id: "only", name: "only-photo", takenAt: 10)
        let loader = MockManifestLoader()
        loader.setOriginals([only])
        loader.setThumbnails([
            thumbnailSet(for: only, widths: [150]),
        ])

        let warmed = await warm(loader: loader, itemCount: 5)

        #expect(warmed == [
            DiskCacheWarmRequest(
                itemId: "only",
                lfsPath: thumbnailPath(name: "only-photo-150")
            ),
        ])
    }

    // An original with no thumbnail set cannot be cached. It must not
    // take the place of a neighbor that can.
    @Test("Warming skips an original that has no thumbnail")
    func testSkipsOriginalWithoutThumbnail() async {
        let missing = original(id: "missing", name: "missing-photo", takenAt: 10)
        let present = original(id: "present", name: "present-photo", takenAt: 20)
        let loader = MockManifestLoader()
        loader.setOriginals([missing, present])
        loader.setThumbnails([
            thumbnailSet(for: present, widths: [225]),
        ])

        let warmed = await warm(loader: loader, itemCount: 5)

        #expect(warmed.map(\.itemId) == ["present"])
    }

    // Expiration is checked between thumbnails. The download already
    // in flight can finish; the next one must not start.
    @Test("Warming stops between items when cancelled")
    func testStopsBetweenItemsWhenCancelled() async {
        let loader = MockManifestLoader()
        let originals = (0..<3).map { index in
            original(
                id: "item-\(index)",
                name: "item-\(index)-photo",
                takenAt: TimeInterval(index + 1)
            )
        }
        loader.setOriginals(originals)
        loader.setThumbnails(originals.map { thumbnailSet(for: $0, widths: [225]) })
        let gate = CancelGate()

        var warmed: [String] = []
        await DiskCacheWarming.warmNewest(
            itemCount: 10,
            scope: .all,
            loader: loader,
            isCancelled: { gate.cancelled }
        ) { request in
            warmed.append(request.itemId)
            gate.cancelled = true
        }

        #expect(warmed == ["item-0"])
    }

    // A failed download is that thumbnail's problem. The rest of the
    // newest page still needs to land before the wake ends.
    @Test("A failed thumbnail does not stop the rest of the page")
    func testFailureSkipsThatItemAndContinues() async {
        let first = original(id: "first", name: "first-photo", takenAt: 10)
        let second = original(id: "second", name: "second-photo", takenAt: 20)
        let loader = MockManifestLoader()
        loader.setOriginals([first, second])
        loader.setThumbnails([
            thumbnailSet(for: first, widths: [225]),
            thumbnailSet(for: second, widths: [225]),
        ])

        var warmed: [String] = []
        await DiskCacheWarming.warmNewest(
            itemCount: 5,
            scope: .all,
            loader: loader
        ) { request in
            warmed.append(request.itemId)
            if request.itemId == "first" {
                throw WarmFailed()
            }
        }

        #expect(warmed == ["first", "second"])
    }

    private func warm(
        loader: MockManifestLoader,
        itemCount: Int
    ) async -> [DiskCacheWarmRequest] {
        var warmed: [DiskCacheWarmRequest] = []
        await DiskCacheWarming.warmNewest(
            itemCount: itemCount,
            scope: .all,
            loader: loader
        ) { request in
            warmed.append(request)
        }
        return warmed
    }

    private func original(
        id: String,
        name: String,
        takenAt: TimeInterval
    ) -> OriginalManifest {
        OriginalManifest(
            id: id,
            localID: nil,
            sha256: "sha-\(id)",
            path: "/tmp/\(id).jpg",
            filesize: 10,
            name: name,
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
            takenAt: Date(timeIntervalSince1970: takenAt),
            guessedTakenAt: Date(timeIntervalSince1970: takenAt)
        )
    }

    private func thumbnailSet(
        for original: OriginalManifest,
        widths: [Int]
    ) -> ThumbnailSetManifest {
        ThumbnailSetManifest(
            originalRef: "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)",
            thumbnails: widths.map { width in
                .init(
                    name: "\(original.metadata.name)-\(width)",
                    sha256: "thumb-\(width)",
                    width: width,
                    height: width,
                    filesize: 10
                )
            },
            name: "\(original.metadata.name)-thumbs",
            deviceSpace: "device-a"
        )
    }

    private func thumbnailPath(name: String) -> String {
        "binary/device-a/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(name))"
    }
}

private struct WarmFailed: Error {}

private final class CancelGate: @unchecked Sendable {
    var cancelled = false
}
