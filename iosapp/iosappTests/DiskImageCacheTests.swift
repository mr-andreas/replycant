import Foundation
import Testing
@testable import iosapp

// Verifies DiskImageCache LRU eviction, persistence, and stats
// so we can trust the on-disk layer before integrating it into
// the read path.
struct DiskImageCacheTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Round-trip

    @Test func storeAndRetrieve() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        let payload = Data(repeating: 0xAB, count: 256)
        await cache.store(payload, forKey: "t/photo1")

        let retrieved = await cache.data(forKey: "t/photo1")
        #expect(retrieved == payload)
    }

    @Test func missingKeyReturnsNil() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        let result = await cache.data(forKey: "nonexistent")
        #expect(result == nil)
    }

    // MARK: - LRU eviction

    @Test func evictsLeastRecentlyUsedWhenOverLimit() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 500)
        await cache.rebuild()

        let a = Data(repeating: 0x01, count: 200)
        let b = Data(repeating: 0x02, count: 200)
        await cache.store(a, forKey: "a")
        await cache.store(b, forKey: "b")

        // Both fit (400 <= 500)
        #expect(await cache.data(forKey: "a") != nil)
        #expect(await cache.data(forKey: "b") != nil)

        // Touch "a" so "b" becomes least-recently-used
        _ = await cache.data(forKey: "a")

        // Adding "c" (200 bytes) pushes total to 600 > 500, evicting "b"
        let c = Data(repeating: 0x03, count: 200)
        await cache.store(c, forKey: "c")

        #expect(await cache.data(forKey: "a") != nil)
        #expect(await cache.data(forKey: "b") == nil)
        #expect(await cache.data(forKey: "c") != nil)
    }

    @Test func evictsMultipleEntriesIfNeeded() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 500)
        await cache.rebuild()

        let small = Data(repeating: 0x01, count: 100)
        for i in 0..<5 {
            await cache.store(small, forKey: "k\(i)")
        }
        #expect(await cache.itemCount == 5)

        // Storing a 400-byte entry must evict several smaller ones
        let big = Data(repeating: 0xFF, count: 400)
        await cache.store(big, forKey: "big")

        #expect(await cache.currentSizeBytes <= 500)
        #expect(await cache.data(forKey: "big") != nil)
    }

    // MARK: - removeAll

    @Test func removeAllClearsEverything() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        await cache.store(Data(repeating: 0x01, count: 100), forKey: "x")
        await cache.store(Data(repeating: 0x02, count: 100), forKey: "y")
        #expect(await cache.itemCount == 2)

        await cache.removeAll()
        #expect(await cache.itemCount == 0)
        #expect(await cache.currentSizeBytes == 0)
        #expect(await cache.data(forKey: "x") == nil)
    }

    // MARK: - Stats

    @Test func sizeAndCountAccurate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        #expect(await cache.itemCount == 0)
        #expect(await cache.currentSizeBytes == 0)

        await cache.store(Data(repeating: 0x01, count: 300), forKey: "a")
        await cache.store(Data(repeating: 0x02, count: 200), forKey: "b")

        #expect(await cache.itemCount == 2)
        #expect(await cache.currentSizeBytes == 500)
    }

    // MARK: - Persistence across re-init

    @Test func rebuildFromDiskOnReInit() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache1 = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache1.rebuild()
        await cache1.store(Data(repeating: 0xAA, count: 128), forKey: "persist")

        // Create a new instance pointing at the same directory
        let cache2 = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache2.rebuild()

        #expect(await cache2.itemCount == 1)
        let data = await cache2.data(forKey: "persist")
        #expect(data == Data(repeating: 0xAA, count: 128))
    }

    // MARK: - setMaxBytes triggers eviction

    @Test func setMaxBytesShrinkEvicts() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        for i in 0..<10 {
            await cache.store(Data(repeating: UInt8(i), count: 100), forKey: "k\(i)")
        }
        #expect(await cache.currentSizeBytes == 1000)

        await cache.setMaxBytes(300)
        #expect(await cache.currentSizeBytes <= 300)
        #expect(await cache.itemCount <= 3)
    }

    // MARK: - Overwrite existing key

    @Test func storeOverwritesExistingKey() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 1_000_000)
        await cache.rebuild()

        await cache.store(Data(repeating: 0x01, count: 100), forKey: "k")
        await cache.store(Data(repeating: 0x02, count: 200), forKey: "k")

        #expect(await cache.itemCount == 1)
        #expect(await cache.currentSizeBytes == 200)
        let data = await cache.data(forKey: "k")
        #expect(data == Data(repeating: 0x02, count: 200))
    }

    // MARK: - Entry too large for cache

    @Test func entryLargerThanMaxIsNotStored() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let cache = DiskImageCache(directory: dir, maxBytes: 100)
        await cache.rebuild()

        await cache.store(Data(repeating: 0xFF, count: 200), forKey: "huge")
        #expect(await cache.data(forKey: "huge") == nil)
        #expect(await cache.itemCount == 0)
    }
}
