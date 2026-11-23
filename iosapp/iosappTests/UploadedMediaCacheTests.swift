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
        cache.confirm(cache.pendingSnapshot())

        let reloaded = UploadedMediaCache(fileURL: fileURL)
        #expect(reloaded.contains(localID: "asset-1", modifiedAt: "2026-01-01T00:00:00Z"))
    }

    // A staged photo is not uploaded until its commit is pushed, so a
    // scan must not treat it as already on the server.
    @Test("pending entries require confirm")
    func pendingEntriesRequireConfirm() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z")

        #expect(cache.contains(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z") == false)

        cache.confirm(cache.pendingSnapshot())
        #expect(cache.contains(localID: "asset-2", modifiedAt: "2026-01-02T00:00:00Z"))
    }

    // A photo committed while a push is in flight was not part of that
    // push, so confirming the earlier snapshot must leave it staged.
    @Test("confirm persists only the snapshotted entries")
    func confirmPersistsOnlyTheSnapshot() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-a", modifiedAt: "2026-01-05T00:00:00Z")
        let snapshot = cache.pendingSnapshot()
        cache.addPending(localID: "asset-b", modifiedAt: "2026-01-06T00:00:00Z")
        cache.confirm(snapshot)

        let reloaded = UploadedMediaCache(fileURL: fileURL)
        #expect(reloaded.contains(localID: "asset-a", modifiedAt: "2026-01-05T00:00:00Z"))
        #expect(reloaded.contains(localID: "asset-b", modifiedAt: "2026-01-06T00:00:00Z") == false)

        cache.confirm(cache.pendingSnapshot())
        let afterLaterConfirm = UploadedMediaCache(fileURL: fileURL)
        #expect(afterLaterConfirm.contains(localID: "asset-b", modifiedAt: "2026-01-06T00:00:00Z"))
    }

    // Discard can finish while a push that already copied the staged
    // set is still running. That copy must not recreate the skip file.
    @Test("confirm after clear writes nothing")
    func confirmAfterClearWritesNothing() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-5", modifiedAt: "2026-01-07T00:00:00Z")
        let snapshot = cache.pendingSnapshot()
        cache.clear()
        cache.confirm(snapshot)

        #expect(cache.contains(localID: "asset-5", modifiedAt: "2026-01-07T00:00:00Z") == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    // Ensures clear resets both persisted and pending state for reset-and-resync flows.
    @Test("clear removes persisted and pending entries")
    func clearRemovesPersistedAndPendingEntries() throws {
        let fileURL = makeCacheFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let cache = UploadedMediaCache(fileURL: fileURL)
        cache.addPending(localID: "asset-3", modifiedAt: "2026-01-03T00:00:00Z")
        cache.confirm(cache.pendingSnapshot())
        cache.addPending(localID: "asset-4", modifiedAt: "2026-01-04T00:00:00Z")

        cache.clear()

        #expect(cache.contains(localID: "asset-3", modifiedAt: "2026-01-03T00:00:00Z") == false)
        #expect(cache.contains(localID: "asset-4", modifiedAt: "2026-01-04T00:00:00Z") == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }
}
