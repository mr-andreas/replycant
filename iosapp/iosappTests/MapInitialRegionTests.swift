import CoreLocation
import MapKit
import Testing
@testable import iosapp

// The map should open on the place the library actually lives, so a
// trip or a bad coordinate cannot zoom it out to the whole world.
struct MapInitialRegionTests {
    // A library that never leaves one city should still open on that
    // city, with enough span that a single block is not street-level.
    @Test func cityPhotosFrameThatCity() throws {
        let region = try #require(MapInitialRegion.region(for: [
            point("a", latitude: 59.32, longitude: 18.05, takenAt: 1),
            point("b", latitude: 59.34, longitude: 18.07, takenAt: 2),
            point("c", latitude: 59.33, longitude: 18.06, takenAt: 3),
        ]))

        #expect(abs(region.center.latitude - 59.33) < 0.001)
        #expect(abs(region.center.longitude - 18.06) < 0.001)
        #expect(region.span.latitudeDelta >= 0.08)
        #expect(region.span.longitudeDelta >= 0.08)
        #expect(region.span.latitudeDelta < 1)
        #expect(region.span.longitudeDelta < 1)
    }

    // One placed photo has no extent, so the floor span is what keeps
    // the map from opening on a single building.
    @Test func singlePhotoUsesMinimumSpan() throws {
        let region = try #require(MapInitialRegion.region(for: [
            point("only", latitude: 59.33, longitude: 18.06, takenAt: 1),
        ]))

        #expect(region.center.latitude == 59.33)
        #expect(region.center.longitude == 18.06)
        #expect(region.span.latitudeDelta == 0.08)
        #expect(region.span.longitudeDelta == 0.08)
    }

    // Distant trips must not stretch the opening view. The dense part
    // of the library decides the camera, and the span stays country-sized.
    @Test func outliersDoNotPullTheCameraToTheWorld() throws {
        var points = (0..<20).map { index in
            point(
                "se-\(index)",
                latitude: 59.33,
                longitude: 18.06,
                takenAt: TimeInterval(index)
            )
        }
        // Edges of the country window around the Stockholm cell, so the
        // uncapped box would exceed a country and must be clamped.
        points.append(point("north", latitude: 65.5, longitude: 18.06, takenAt: 30))
        points.append(point("south", latitude: 53.5, longitude: 18.06, takenAt: 31))
        points.append(point("ny", latitude: 40.7, longitude: -74.0, takenAt: 40))
        points.append(point("tokyo", latitude: 35.6, longitude: 139.7, takenAt: 41))

        let region = try #require(MapInitialRegion.region(for: points))
        #expect(region.center.latitude > 55 && region.center.latitude < 70)
        #expect(region.center.longitude > 10 && region.center.longitude < 25)
        #expect(region.span.latitudeDelta == 12)
        #expect(region.span.longitudeDelta <= 12)
    }

    // Two homes: open on the one with more photos, not the ocean between them.
    @Test func splitLibraryOpensOnTheSideWithMorePhotos() throws {
        var points = (0..<5).map { index in
            point("us-\(index)", latitude: 40.71, longitude: -74.01, takenAt: TimeInterval(index))
        }
        points += (0..<12).map { index in
            point("se-\(index)", latitude: 59.33, longitude: 18.06, takenAt: TimeInterval(100 + index))
        }

        let region = try #require(MapInitialRegion.region(for: points))
        #expect(abs(region.center.latitude - 59.33) < 0.001)
        #expect(abs(region.center.longitude - 18.06) < 0.001)
    }

    // Equal counts are still deterministic: the newer photo's cell wins,
    // so two homes do not jump between launches.
    @Test func tiedCellsPreferTheNewestPhoto() throws {
        let region = try #require(MapInitialRegion.region(for: [
            point("older", latitude: 59.33, longitude: 18.06, takenAt: 1),
            point("newer", latitude: 40.71, longitude: -74.01, takenAt: 50),
        ]))

        #expect(abs(region.center.latitude - 40.71) < 0.001)
        #expect(abs(region.center.longitude - (-74.01)) < 0.001)
    }

    // Null Island and corrupt coordinates must not move the camera.
    @Test func invalidCoordinatesAreIgnored() throws {
        let city = [
            point("a", latitude: 59.33, longitude: 18.06, takenAt: 1),
            point("b", latitude: 59.40, longitude: 18.20, takenAt: 2),
        ]
        let junk = city + [
            point("origin", latitude: 0, longitude: 0, takenAt: 9),
            point("lat", latitude: 120, longitude: 18, takenAt: 10),
            point("lon", latitude: 59, longitude: 200, takenAt: 11),
            point("south", latitude: -100, longitude: 18, takenAt: 12),
            point("west", latitude: 59, longitude: -200, takenAt: 13),
        ]

        let withJunk = try #require(MapInitialRegion.region(for: junk))
        let clean = try #require(MapInitialRegion.region(for: city))
        #expect(withJunk.center.latitude == clean.center.latitude)
        #expect(withJunk.center.longitude == clean.center.longitude)
        #expect(withJunk.span.latitudeDelta == clean.span.latitudeDelta)
        #expect(withJunk.span.longitudeDelta == clean.span.longitudeDelta)
    }

    // Photos just across the dateline are neighbors. The opening span
    // should be the gap between them, not a box the long way around the world.
    @Test func datelinePhotosStayInOneSmallRegion() throws {
        let region = try #require(MapInitialRegion.region(for: [
            point("east", latitude: 35.0, longitude: 179.6, takenAt: 1),
            point("west", latitude: 35.2, longitude: -179.4, takenAt: 2),
        ]))

        #expect(abs(region.center.longitude) > 170)
        #expect(region.span.longitudeDelta < 12)
        #expect(region.span.latitudeDelta < 1)
    }

    // Nothing to frame: the map keeps its automatic camera.
    @Test func noValidPointsReturnsNil() {
        #expect(MapInitialRegion.region(for: []) == nil)
        #expect(MapInitialRegion.region(for: [
            point("origin", latitude: 0, longitude: 0, takenAt: 1),
            point("bad", latitude: 95, longitude: 10, takenAt: 2),
        ]) == nil)
    }

    private func point(
        _ id: String,
        latitude: Double,
        longitude: Double,
        takenAt: TimeInterval
    ) -> MapMediaPoint {
        MapMediaPoint(
            id: id,
            latitude: latitude,
            longitude: longitude,
            takenAt: Date(timeIntervalSince1970: takenAt)
        )
    }
}
