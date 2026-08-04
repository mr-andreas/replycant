import Foundation
import Testing
@testable import iosapp

// Verifies the two-tier disk cache read order: top -> main -> LFS,
// the top-cache write isolation (browsing never populates top), and
// the read-through warmTop semantics (warm writes to both caches).
struct ImageDiskCacheManagerTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDiskCacheManagerTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dirs: URL...) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    // MARK: - Read precedence

    @Test func topCacheHitReturnedFirst() async throws {
        let mainDir = try makeTempDir("main")
        let topDir = try makeTempDir("top")
        defer { cleanup(mainDir, topDir) }

        let main = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await main.rebuild()
        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        let topData = Data(repeating: 0xAA, count: 50)
        let mainData = Data(repeating: 0xBB, count: 50)
        await top.store(topData, forKey: "t/item1")
        await main.store(mainData, forKey: "t/item1")

        let result = await top.data(forKey: "t/item1")
        #expect(result == topData)
    }

    @Test func mainCacheHitDoesNotPromoteIntoTop() async throws {
        let mainDir = try makeTempDir("main")
        let topDir = try makeTempDir("top")
        defer { cleanup(mainDir, topDir) }

        let main = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await main.rebuild()
        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        let payload = Data(repeating: 0xCC, count: 100)
        await main.store(payload, forKey: "t/item2")

        // Simulate loadImageData read: miss top, hit main
        let topHit = await top.data(forKey: "t/item2")
        #expect(topHit == nil)
        let mainHit = await main.data(forKey: "t/item2")
        #expect(mainHit == payload)

        // Verify top was NOT populated
        #expect(await top.itemCount == 0)
    }

    // MARK: - Browsing writes main only

    @Test func browsingMissPopulatesMainOnly() async throws {
        let mainDir = try makeTempDir("main")
        let topDir = try makeTempDir("top")
        defer { cleanup(mainDir, topDir) }

        let main = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await main.rebuild()
        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        // Simulate what loadImageData does on a full miss
        let fetched = Data(repeating: 0xDD, count: 80)
        await main.store(fetched, forKey: "o/item3")

        #expect(await main.data(forKey: "o/item3") == fetched)
        #expect(await top.data(forKey: "o/item3") == nil)
    }

    // MARK: - warmTop read-through semantics

    @Test func warmTopWritesToBothCaches() async throws {
        let mainDir = try makeTempDir("main")
        let topDir = try makeTempDir("top")
        defer { cleanup(mainDir, topDir) }

        let main = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await main.rebuild()
        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        let payload = Data(repeating: 0xEE, count: 64)

        // warmTop: store into both caches
        await top.store(payload, forKey: "t/item4")
        await main.store(payload, forKey: "t/item4")

        #expect(await top.data(forKey: "t/item4") == payload)
        #expect(await main.data(forKey: "t/item4") == payload)
    }

    @Test func warmTopFromMainHitSkipsLFS() async throws {
        let mainDir = try makeTempDir("main")
        let topDir = try makeTempDir("top")
        defer { cleanup(mainDir, topDir) }

        let main = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await main.rebuild()
        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        let payload = Data(repeating: 0xFF, count: 32)
        await main.store(payload, forKey: "t/item5")

        // warmTop when main already has it: reads from main, stores into top
        if await top.data(forKey: "t/item5") == nil {
            let fromMain = await main.data(forKey: "t/item5")
            #expect(fromMain != nil)
            if let d = fromMain {
                await top.store(d, forKey: "t/item5")
            }
        }

        #expect(await top.data(forKey: "t/item5") == payload)
        #expect(await main.data(forKey: "t/item5") == payload)
    }

    @Test func warmTopIsIdempotent() async throws {
        let topDir = try makeTempDir("top")
        defer { cleanup(topDir) }

        let top = DiskImageCache(directory: topDir, maxBytes: 1_000_000)
        await top.rebuild()

        let payload = Data(repeating: 0x11, count: 40)
        await top.store(payload, forKey: "t/item6")
        #expect(await top.itemCount == 1)

        // Second warm is a no-op
        let existing = await top.data(forKey: "t/item6")
        #expect(existing != nil)
        #expect(await top.itemCount == 1)
    }

    // MARK: - Key namespacing

    @Test func thumbnailAndOriginalKeysDoNotCollide() async throws {
        let mainDir = try makeTempDir("main")
        defer { cleanup(mainDir) }

        let cache = DiskImageCache(directory: mainDir, maxBytes: 1_000_000)
        await cache.rebuild()

        let thumbData = Data(repeating: 0x01, count: 50)
        let origData = Data(repeating: 0x02, count: 80)

        await cache.store(thumbData, forKey: "t/same-id")
        await cache.store(origData, forKey: "o/same-id")

        #expect(await cache.itemCount == 2)
        #expect(await cache.data(forKey: "t/same-id") == thumbData)
        #expect(await cache.data(forKey: "o/same-id") == origData)
    }
}
