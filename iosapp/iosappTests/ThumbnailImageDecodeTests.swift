import UIKit
import Testing
@testable import iosapp

// A thumbnail file that is not an image used to stay in the cache, so
// the cell kept showing the empty placeholder. One fresh read replaces it.
@MainActor
struct ThumbnailImageDecodeTests {
    private func png() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData() ?? Data()
    }

    @Test func readableBytesAreKept() async throws {
        let bytes = png()
        var drops = 0
        var fetches = 0

        let image = try await ThumbnailImageDecode.image(
            from: bytes,
            invalidate: { drops += 1 },
            refetch: {
                fetches += 1
                return bytes
            }
        )

        #expect(image != nil)
        #expect(drops == 0)
        #expect(fetches == 0)
    }

    @Test func undecodableBytesAreDroppedAndTheRefetchIsShown() async throws {
        let bytes = png()
        var drops = 0
        var fetches = 0

        let image = try await ThumbnailImageDecode.image(
            from: Data([0x00, 0x01, 0x02]),
            invalidate: { drops += 1 },
            refetch: {
                fetches += 1
                return bytes
            }
        )

        #expect(image != nil)
        #expect(drops == 1)
        #expect(fetches == 1)
    }

    @Test func aSecondUndecodableReadIsDroppedToo() async throws {
        var drops = 0

        let image = try await ThumbnailImageDecode.image(
            from: Data([0x00]),
            invalidate: { drops += 1 },
            refetch: { Data([0x01, 0x02]) }
        )

        #expect(image == nil)
        #expect(drops == 2)
    }

    @Test func aFailedRefetchStillDropsTheCachedBytes() async {
        struct ProbeError: Error {}
        var drops = 0

        await #expect(throws: ProbeError.self) {
            try await ThumbnailImageDecode.image(
                from: Data([0x00]),
                invalidate: { drops += 1 },
                refetch: { throw ProbeError() }
            )
        }
        #expect(drops == 1)
    }
}
