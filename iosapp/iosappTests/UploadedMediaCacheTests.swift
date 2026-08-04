import Foundation
import Testing
@testable import iosapp

// Verifies uploaded-media cache persistence and pending-flush behavior.
@MainActor
@Suite("UploadedMediaCache Tests")
struct UploadedMediaCacheTests {
    // Creates isolated cache file URLs so test runs never share state.
    private func makeCacheFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-media-cache-\(UUID().uuidString).json")
    }

    // Ensures persisted entries survive a reload from disk.
    @Test("persisted entries survive reload")
    func persistedEntriesSurviveReload() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-1", modifiedAt: "2026-01-01T00:00:00Z")
        cache.flushPending()

        let reloaded = UploadedMediaCache(fileURL: fileURL)
        #expect(reloaded.contains(localID: "asset-1", modifiedAt: "2026-01-01T00:00:00Z"))
    }

    // Ensures pending entries are invisible until a push-success flush confirms them.
    @Test("pending entries require flush")
    func pendingEntriesRequireFlush() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z")

        #expect(cache.contains(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z") == false)

        cache.flushPending()
        #expect(cache.contains(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z"))
    }

    // Ensures clear resets both persisted and pending state for reset-and-resync flows.
    @Test("clear removes persisted and pending entries")
    func clearRemovesPersistedAndPendingEntries() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-3", modifiedAt: "2026-01-03T00:00:00Z")
        cache.flushPending()
        cache.addPending(localID: "asset-4", modifiedAt: "2026-01-04T00:00:00Z")

        cache.clear()

        #expect(cache.contains(localID: "asset-3", modifiedAt: "2026-01-03T00:00:00Z") == false)
        #expect(cache.contains(localID: "asset-4", modifiedAt: "2026-01-04T00:00:00Z") == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }
}
