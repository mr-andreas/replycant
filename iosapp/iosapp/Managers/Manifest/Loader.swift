import Foundation
import GitDB

typealias NotSupportedError = GitDB.NotSupportedError

// Identifies one deterministic timeline position for cursor-based pagination stability.
struct TimelineCursor {
    let date: Date
    let id: String
}

// Carries one grouped timeline month so UI jump navigation can map month labels to global offsets.
struct TimelineMonthCount {
    let year: Int
    let month: Int
    let count: Int
}

// Defines app-specific manifest read operations on top of GitDB's generic query API.
protocol ManifestLoaderProtocol {
    func loadManifest<T: Manifest>(deviceSpace: String?, id: String) async throws -> T?
    func loadAllManifests<T: Manifest>(deviceSpace: String?) async throws -> [T]
    func countTimelineOriginals() async throws -> Int
    func loadTimelinePage(offset: Int, limit: Int) async throws -> [OriginalManifest]
    func loadTimelinePage(before: TimelineCursor, limit: Int) async throws -> [OriginalManifest]
    func loadTimelinePage(after: TimelineCursor, limit: Int) async throws -> [OriginalManifest]
    func loadTimelineMonthCounts() async throws -> [TimelineMonthCount]
    func loadThumbnailsByOriginalRefs(_ refs: [String]) async throws -> [String: ThumbnailSetManifest]
}