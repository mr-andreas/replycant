import Foundation
import GitDB

typealias NotSupportedError = GitDB.NotSupportedError

// A lat/lon box around the photos in one map tile. The place grid queries
// this box so its count matches the tile without listing every id.
struct GeoBounds: Equatable, Hashable, Sendable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLatitude && latitude <= maxLatitude
            && longitude >= minLongitude && longitude <= maxLongitude
    }
}

// Narrows timeline reads to the photos a screen is allowed to show.
// The map and a place grid reuse the timeline by changing only this.
enum TimelineScope: Equatable, Sendable {
    case all
    case geotagged
    case area(GeoBounds)

    // Keeps sparse-window index math aligned with the SQL predicate, so a
    // sync that adds a photo outside the place does not shift offsets.
    func contains(_ original: OriginalManifest) -> Bool {
        guard original.spec.takenAt != nil else { return false }
        switch self {
        case .all:
            return true
        case .geotagged:
            return original.spec.location != nil
        case .area(let bounds):
            guard let location = original.spec.location else { return false }
            return bounds.contains(
                latitude: location.latitude,
                longitude: location.longitude
            )
        }
    }
}

// One geotagged photo reduced to the fields the map clusters on, so
// clustering does not decode full manifests for the whole library.
struct MapMediaPoint: Equatable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let takenAt: Date
}

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
    func countTimelineOriginals(scope: TimelineScope) async throws -> Int
    func loadTimelinePage(offset: Int, limit: Int, scope: TimelineScope) async throws -> [OriginalManifest]
    func loadTimelinePage(before: TimelineCursor, limit: Int, scope: TimelineScope) async throws -> [OriginalManifest]
    func loadTimelinePage(after: TimelineCursor, limit: Int, scope: TimelineScope) async throws -> [OriginalManifest]
    func loadTimelineMonthCounts(scope: TimelineScope) async throws -> [TimelineMonthCount]
    func loadGeotaggedPoints() async throws -> [MapMediaPoint]
    func loadOriginals(ids: [String]) async throws -> [OriginalManifest]
    func loadThumbnailsByOriginalRefs(_ refs: [String]) async throws -> [String: ThumbnailSetManifest]
}

// Keeps existing call sites on the full library. Screens that show a
// place pass an explicit scope instead.
extension ManifestLoaderProtocol {
    func countTimelineOriginals() async throws -> Int {
        try await countTimelineOriginals(scope: .all)
    }

    func loadTimelinePage(offset: Int, limit: Int) async throws -> [OriginalManifest] {
        try await loadTimelinePage(offset: offset, limit: limit, scope: .all)
    }

    func loadTimelinePage(before: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        try await loadTimelinePage(before: before, limit: limit, scope: .all)
    }

    func loadTimelinePage(after: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        try await loadTimelinePage(after: after, limit: limit, scope: .all)
    }

    func loadTimelineMonthCounts() async throws -> [TimelineMonthCount] {
        try await loadTimelineMonthCounts(scope: .all)
    }
}