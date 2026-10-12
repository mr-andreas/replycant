import CoreLocation
import MapKit
import Testing
@testable import iosapp

// Verifies map tiles split as the user zooms and never claim photos
// that are off screen, including when the view crosses the dateline.
struct MapClustererTests {
    private let viewSize = CGSize(width: 400, height: 800)

    // Zooming out should keep a neighborhood in one tile, and zooming
    // in should separate those same photos into smaller groups.
    @Test func nearbyPointsMergeWhenZoomedOutAndSplitWhenZoomedIn() {
        let older = point("older", latitude: 59.33, longitude: 18.06, takenAt: 10)
        let newer = point("newer", latitude: 59.34, longitude: 18.07, takenAt: 20)
        let center = CLLocationCoordinate2D(latitude: 59.335, longitude: 18.065)

        let zoomedOut = MapClusterer.clusters(
            from: [older, newer],
            visibleMapRect: mapRect(center: center, latitudeDelta: 20, viewSize: viewSize),
            viewSize: viewSize
        )
        #expect(zoomedOut.count == 1)
        guard zoomedOut.count == 1 else { return }
        #expect(zoomedOut[0].count == 2)

        let zoomedIn = MapClusterer.clusters(
            from: [older, newer],
            visibleMapRect: mapRect(center: center, latitudeDelta: 0.014, viewSize: viewSize),
            viewSize: viewSize
        )
        #expect(zoomedIn.count == 2)
        #expect(Set(zoomedIn.map(\.representativeId)) == ["older", "newer"])
    }

    // The tile photo is the newest member. The pin itself sits at the
    // members' centroid so a tile shows the place, not only that photo.
    @Test func representativeIsTheNewestMember() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let probe = mapRect(center: center, latitudeDelta: 1, viewSize: viewSize)
        let rect = centeredOnCell(probe, around: center)
        let cell = MapClusterer.cellMapSize(visibleMapRect: rect, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let older = point(at: origin, dx: 0.40, dy: 0.40, cell: cell, id: "older", takenAt: 10)
        let middle = point(at: origin, dx: 0.60, dy: 0.40, cell: cell, id: "middle", takenAt: 20)
        let newer = point(at: origin, dx: 0.40, dy: 0.60, cell: cell, id: "newer", takenAt: 30)
        let clusters = MapClusterer.clusters(
            from: [older, middle, newer],
            visibleMapRect: rect,
            viewSize: viewSize
        )
        let centroid = mapCentroid([older, middle, newer])
        #expect(clusters.count == 1)
        #expect(clusters[0].representativeId == "newer")
        #expect(abs(clusters[0].latitude - centroid.latitude) < 1e-6)
        #expect(abs(clusters[0].longitude - centroid.longitude) < 1e-6)
    }

    // The place grid uses the members' own bounds, so the tile count
    // stays equal to the number of photos the grid will query.
    @Test func boundsAreTheTightBoundsOfMembers() {
        let first = point("first", latitude: 59.33, longitude: 18.06, takenAt: 10)
        let second = point("second", latitude: 59.35, longitude: 18.09, takenAt: 20)
        let center = CLLocationCoordinate2D(latitude: 59.34, longitude: 18.075)
        let clusters = MapClusterer.clusters(
            from: [first, second],
            visibleMapRect: mapRect(center: center, latitudeDelta: 20, viewSize: viewSize),
            viewSize: viewSize
        )
        #expect(clusters.count == 1)
        #expect(clusters[0].bounds == GeoBounds(
            minLatitude: 59.33,
            maxLatitude: 59.35,
            minLongitude: 18.06,
            maxLongitude: 18.09
        ))
    }

    // A cell that only partly overlaps the screen still counts every
    // photo in it. Otherwise the tile's photo and count change as the
    // cell slides into view.
    @Test func edgeCellKeepsOffScreenMembers() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let probe = mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize)
        let cell = MapClusterer.cellMapSize(visibleMapRect: probe, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let rect = rectCuttingCell(origin: origin, cell: cell, size: probe.size, at: 0.5)
        let onScreen = point(at: origin, dx: 0.30, dy: 0.50, cell: cell, id: "on-screen", takenAt: 10)
        let offScreen = point(at: origin, dx: 0.70, dy: 0.50, cell: cell, id: "off-screen", takenAt: 30)
        let clusters = MapClusterer.clusters(
            from: [onScreen, offScreen],
            visibleMapRect: rect,
            viewSize: viewSize
        )
        #expect(clusters.count == 1)
        guard let group = clusters.first else { return }
        #expect(group.count == 2)
        #expect(group.representativeId == "off-screen")
    }

    // Sliding the screen further across the same cell must not rebuild
    // the group, even when a previously hidden member comes into view.
    @Test func panningAcrossAnEdgeDoesNotChangeTheGroup() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let probe = mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize)
        let cell = MapClusterer.cellMapSize(visibleMapRect: probe, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let rect = rectCuttingCell(origin: origin, cell: cell, size: probe.size, at: 0.5)
        let shifted = MKMapRect(
            x: rect.minX + cell * 0.3,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
        let onScreen = point(at: origin, dx: 0.30, dy: 0.50, cell: cell, id: "on-screen", takenAt: 10)
        let offScreen = point(at: origin, dx: 0.70, dy: 0.50, cell: cell, id: "off-screen", takenAt: 30)
        let before = MapClusterer.clusters(
            from: [onScreen, offScreen],
            visibleMapRect: rect,
            viewSize: viewSize
        )
        let after = MapClusterer.clusters(
            from: [onScreen, offScreen],
            visibleMapRect: shifted,
            viewSize: viewSize
        )
        #expect(before == after)
        #expect(before.first?.count == 2)
    }

    // Groups whose cell lies entirely off screen are not drawn.
    @Test func pointsOutsideTheViewAreDropped() {
        let visible = point("visible", latitude: 59.33, longitude: 18.06, takenAt: 10)
        let hidden = point("hidden", latitude: 40.71, longitude: -74.0, takenAt: 20)
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let clusters = MapClusterer.clusters(
            from: [visible, hidden],
            visibleMapRect: mapRect(center: center, latitudeDelta: 1, viewSize: viewSize),
            viewSize: viewSize
        )
        #expect(clusters.map(\.representativeId) == ["visible"])
    }

    // A small pan keeps every group that stays on screen. The grid is
    // fixed to the world, so the view sliding cannot rebuild it.
    @Test func panningDoesNotRegroupPhotos() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let rect = centeredOnCell(
            mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize),
            around: center
        )
        let cell = MapClusterer.cellMapSize(visibleMapRect: rect, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let points = [
            point(at: origin, dx: 0.45, dy: 0.50, cell: cell, id: "left", takenAt: 10),
            point(at: origin, dx: 0.55, dy: 0.50, cell: cell, id: "right", takenAt: 20),
        ]
        let shifted = MKMapRect(
            x: rect.minX + cell * 0.15,
            y: rect.minY + cell * 0.15,
            width: rect.width,
            height: rect.height
        )
        let before = MapClusterer.clusters(from: points, visibleMapRect: rect, viewSize: viewSize)
        let after = MapClusterer.clusters(from: points, visibleMapRect: shifted, viewSize: viewSize)
        #expect(before == after)
    }

    // Zooming a little, without crossing a grid level, keeps the same
    // groups. Groups only split when the zoom crosses a power of two.
    @Test func smallZoomKeepsTheSameGroups() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let rect = centeredOnCell(
            mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize),
            around: center
        )
        let cell = MapClusterer.cellMapSize(visibleMapRect: rect, viewSize: viewSize)
        let onScreen = cell * Double(viewSize.width) / rect.width
        let target = Double(MapClusterer.targetCellSize(for: viewSize))
        let slack = onScreen / target
        let zoomIn = 1 + (2 / slack - 1) * 0.5
        let closer = scaled(rect, by: 1 / zoomIn)
        let origin = cellOrigin(containing: center, cell: cell)
        let points = [
            point(at: origin, dx: 0.48, dy: 0.50, cell: cell, id: "a", takenAt: 1),
            point(at: origin, dx: 0.52, dy: 0.52, cell: cell, id: "b", takenAt: 2),
        ]
        #expect(MapClusterer.cellMapSize(visibleMapRect: closer, viewSize: viewSize) == cell)
        #expect(
            MapClusterer.clusters(from: points, visibleMapRect: rect, viewSize: viewSize)
                == MapClusterer.clusters(from: points, visibleMapRect: closer, viewSize: viewSize)
        )
    }

    // One zoom level splits each group into the smaller cells it was
    // built from, and no photo is gained or lost.
    @Test func zoomingOneLevelSplitsGroupsIntoTheirChildren() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let coarseRect = centeredOnCell(
            mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize),
            around: center
        )
        let fineRect = scaled(coarseRect, by: 0.5)
        let cell = MapClusterer.cellMapSize(visibleMapRect: coarseRect, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let points = [
            point(at: origin, dx: 0.25, dy: 0.50, cell: cell, id: "a", takenAt: 1),
            point(at: origin, dx: 0.75, dy: 0.50, cell: cell, id: "b", takenAt: 2),
        ]
        let coarse = MapClusterer.clusters(from: points, visibleMapRect: coarseRect, viewSize: viewSize)
        let fine = MapClusterer.clusters(from: points, visibleMapRect: fineRect, viewSize: viewSize)
        let fineCell = MapClusterer.cellMapSize(visibleMapRect: fineRect, viewSize: viewSize)
        #expect(abs(cell / fineCell - 2) < 0.001)
        #expect(coarse.reduce(0) { $0 + $1.count } == points.count)
        #expect(fine.reduce(0) { $0 + $1.count } == points.count)
        for child in fine {
            #expect(coarse.contains { contains($0.bounds, child.bounds) })
        }
    }

    // The cell is a power-of-two slice of the world, and on screen it
    // stays between the target size and twice that.
    @Test func cellSizeFollowsZoomAndStaysAPowerOfTwo() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let rect = mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize)
        let cell = MapClusterer.cellMapSize(visibleMapRect: rect, viewSize: viewSize)
        let onScreen = cell * Double(viewSize.width) / rect.width
        let target = Double(MapClusterer.targetCellSize(for: viewSize))
        #expect(onScreen >= target)
        #expect(onScreen < target * 2)
        let ratio = MKMapRect.world.width / cell
        #expect(abs(ratio - ratio.rounded()) / ratio < 1e-8)
        let exponent = log2(ratio.rounded())
        #expect(abs(exponent - exponent.rounded()) < 1e-6)
    }

    // Photos on either side of a cell edge must not draw tiles on top
    // of each other, or there is nowhere to pinch the map.
    @Test func tilesOnEitherSideOfABoundaryStayATileApart() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let probe = mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize)
        let cell = MapClusterer.cellMapSize(visibleMapRect: probe, viewSize: viewSize)
        let anchor = MKMapPoint(center)
        let boundary = MKMapPoint(
            x: (floor(anchor.x / cell) + 1) * cell,
            y: (floor(anchor.y / cell) + 0.5) * cell
        )
        let rect = MKMapRect(
            x: boundary.x - probe.width / 2,
            y: boundary.y - probe.height / 2,
            width: probe.width,
            height: probe.height
        )
        let left = point(
            at: MKMapPoint(x: boundary.x - cell, y: boundary.y - cell * 0.5),
            dx: 0.99, dy: 0, cell: cell, id: "left", takenAt: 1
        )
        let right = point(
            at: MKMapPoint(x: boundary.x, y: boundary.y - cell * 0.5),
            dx: 0.01, dy: 0, cell: cell, id: "right", takenAt: 2
        )
        let clusters = MapClusterer.clusters(from: [left, right], visibleMapRect: rect, viewSize: viewSize)
        #expect(clusters.count == 2)
        let scale = Double(viewSize.width) / rect.width
        let first = MKMapPoint(CLLocationCoordinate2D(latitude: clusters[0].latitude, longitude: clusters[0].longitude))
        let second = MKMapPoint(CLLocationCoordinate2D(latitude: clusters[1].latitude, longitude: clusters[1].longitude))
        let distance = hypot((first.x - second.x) * scale, (first.y - second.y) * scale)
        #expect(distance >= Double(MapClusterTile.size))
    }

    // Different groups never share a box, so each tile's count stays
    // equal to the number of photos its place grid will query.
    @Test func groupBoundsDoNotIntersect() {
        let center = CLLocationCoordinate2D(latitude: 59.33, longitude: 18.06)
        let probe = mapRect(center: center, latitudeDelta: 0.5, viewSize: viewSize)
        let cell = MapClusterer.cellMapSize(visibleMapRect: probe, viewSize: viewSize)
        let anchor = MKMapPoint(center)
        let boundary = MKMapPoint(
            x: (floor(anchor.x / cell) + 1) * cell,
            y: (floor(anchor.y / cell) + 0.5) * cell
        )
        let rect = MKMapRect(
            x: boundary.x - probe.width / 2,
            y: boundary.y - probe.height / 2,
            width: probe.width,
            height: probe.height
        )
        let left = point(
            at: MKMapPoint(x: boundary.x - cell, y: boundary.y - cell * 0.5),
            dx: 0.99, dy: 0, cell: cell, id: "left", takenAt: 1
        )
        let right = point(
            at: MKMapPoint(x: boundary.x, y: boundary.y - cell * 0.5),
            dx: 0.01, dy: 0, cell: cell, id: "right", takenAt: 2
        )
        let clusters = MapClusterer.clusters(from: [left, right], visibleMapRect: rect, viewSize: viewSize)
        #expect(clusters.count == 2)
        guard clusters.count == 2 else { return }
        #expect(!overlaps(clusters[0].bounds, clusters[1].bounds))
    }

    // A view that crosses the 180th meridian is two rectangles in map
    // space. Photos on both sides still belong on the map.
    @Test func viewSpanningAntimeridianIncludesPointsOnBothSides() {
        let east = point("east", latitude: 10, longitude: 179.5, takenAt: 10)
        let west = point("west", latitude: 10, longitude: -179.5, takenAt: 20)
        let middle = point("middle", latitude: 10, longitude: 0, takenAt: 30)
        let clusters = MapClusterer.clusters(
            from: [east, west, middle],
            visibleMapRect: antimeridianRect(latitude: 10),
            viewSize: viewSize
        )
        #expect(Set(clusters.flatMap { cluster in
            cluster.representativeId == "east" || cluster.representativeId == "west"
                ? [cluster.representativeId]
                : []
        }).count == 2)
        let ids = Set(clusters.map(\.representativeId))
        #expect(ids.contains("east"))
        #expect(ids.contains("west"))
        #expect(!ids.contains("middle"))
    }

    // Moves the rect onto the cell that contains the anchor without
    // changing its size, so the snapped cell stays the same.
    private func centeredOnCell(_ rect: MKMapRect, around center: CLLocationCoordinate2D) -> MKMapRect {
        let cell = MapClusterer.cellMapSize(visibleMapRect: rect, viewSize: viewSize)
        let origin = cellOrigin(containing: center, cell: cell)
        let focus = MKMapPoint(x: origin.x + cell / 2, y: origin.y + cell / 2)
        return MKMapRect(
            x: focus.x - rect.width / 2,
            y: focus.y - rect.height / 2,
            width: rect.width,
            height: rect.height
        )
    }

    // Places the view so its right edge cuts the cell at `fraction`,
    // leaving the rest of the cell off the right side of the screen.
    private func rectCuttingCell(
        origin: MKMapPoint,
        cell: Double,
        size: MKMapSize,
        at fraction: Double
    ) -> MKMapRect {
        MKMapRect(
            x: origin.x + cell * fraction - size.width,
            y: origin.y + cell * 0.5 - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func cellOrigin(containing center: CLLocationCoordinate2D, cell: Double) -> MKMapPoint {
        let anchor = MKMapPoint(center)
        return MKMapPoint(
            x: floor(anchor.x / cell) * cell,
            y: floor(anchor.y / cell) * cell
        )
    }

    // dx and dy are fractions of a cell, so a test can sit a photo
    // inside a known grid cell.
    private func point(
        at origin: MKMapPoint,
        dx: Double,
        dy: Double,
        cell: Double,
        id: String,
        takenAt: TimeInterval
    ) -> MapMediaPoint {
        let coordinate = MKMapPoint(x: origin.x + dx * cell, y: origin.y + dy * cell).coordinate
        return point(id, latitude: coordinate.latitude, longitude: coordinate.longitude, takenAt: takenAt)
    }

    private func mapCentroid(_ points: [MapMediaPoint]) -> CLLocationCoordinate2D {
        var x = 0.0
        var y = 0.0
        for item in points {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude))
            x += mapPoint.x
            y += mapPoint.y
        }
        let count = Double(points.count)
        return MKMapPoint(x: x / count, y: y / count).coordinate
    }

    private func scaled(_ rect: MKMapRect, by factor: Double) -> MKMapRect {
        let width = rect.width * factor
        let height = rect.height * factor
        return MKMapRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func contains(_ outer: GeoBounds, _ inner: GeoBounds) -> Bool {
        inner.minLatitude >= outer.minLatitude
            && inner.maxLatitude <= outer.maxLatitude
            && inner.minLongitude >= outer.minLongitude
            && inner.maxLongitude <= outer.maxLongitude
    }

    private func overlaps(_ lhs: GeoBounds, _ rhs: GeoBounds) -> Bool {
        lhs.minLatitude <= rhs.maxLatitude && rhs.minLatitude <= lhs.maxLatitude
            && lhs.minLongitude <= rhs.maxLongitude && rhs.minLongitude <= lhs.maxLongitude
    }

    private func point(_ id: String, latitude: Double, longitude: Double, takenAt: TimeInterval) -> MapMediaPoint {
        MapMediaPoint(
            id: id,
            latitude: latitude,
            longitude: longitude,
            takenAt: Date(timeIntervalSince1970: takenAt)
        )
    }

    // Builds the map rectangle a view of this size would show for a
    // latitude span, so zoom tests describe a camera rather than raw points.
    private func mapRect(center: CLLocationCoordinate2D, latitudeDelta: Double, viewSize: CGSize) -> MKMapRect {
        let aspect = viewSize.width / viewSize.height
        let latitudeRadians = center.latitude * .pi / 180
        let longitudeDelta = latitudeDelta * aspect / cos(latitudeRadians)
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude + latitudeDelta / 2,
            longitude: center.longitude - longitudeDelta / 2
        ))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: center.latitude - latitudeDelta / 2,
            longitude: center.longitude + longitudeDelta / 2
        ))
        return MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
    }

    // Extends a rectangle past the eastern edge of the world so the
    // wrapped remainder covers a point just west of the dateline.
    private func antimeridianRect(latitude: Double) -> MKMapRect {
        let worldWidth = MKMapRect.world.width
        let east = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 179.5))
        let west = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: -179.5))
        let padding = worldWidth * 0.01
        return MKMapRect(
            x: east.x - padding,
            y: east.y - padding,
            width: (worldWidth - east.x) + west.x + padding * 2,
            height: padding * 2
        )
    }
}
