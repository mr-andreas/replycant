import CoreLocation
import MapKit

// One map tile: the newest photo, how many photos it stands for, where
// the tile is drawn, and the box the place grid queries.
struct MapCluster: Equatable {
    let count: Int
    let representativeId: String
    let latitude: Double
    let longitude: Double
    let bounds: GeoBounds
}

// Groups geotagged photos into tiles that stay put while the map pans.
// The grid is locked to the world and only changes when zoom crosses a
// step, the same idea as clustering once per integer zoom. Built-in
// MapKit clustering would need one annotation per photo, which does not
// scale to a full library.
enum MapClusterer {
    // Space between neighboring tiles, on top of the tiles themselves,
    // so a dense area still has somewhere to pinch.
    static let tileGap: CGFloat = 8

    // Clusters photos into world-aligned cells, then draws the cells
    // that meet the screen. A cell's count and photo come from every
    // member, so a pan can only show or hide a whole group.
    static func clusters(
        from points: [MapMediaPoint],
        visibleMapRect: MKMapRect,
        viewSize: CGSize,
        tileSize: CGFloat = MapClusterTile.size
    ) -> [MapCluster] {
        guard viewSize.width > 0, visibleMapRect.width > 0 else { return [] }
        let rects = wrappedRects(for: visibleMapRect)
        guard !rects.isEmpty else { return [] }
        let cell = cellMapSize(visibleMapRect: visibleMapRect, viewSize: viewSize, tileSize: tileSize)
        guard cell > 0, cell.isFinite else { return [] }
        let pointsPerMapPoint = Double(viewSize.width) / visibleMapRect.width
        let onScreen = cell * pointsPerMapPoint
        // Half a tile plus the gap, but never more than half the cell,
        // so a tile is pushed off a cell edge it would otherwise cover.
        let insetScreen = min(Double(tileSize) / 2 + Double(tileGap), onScreen / 2)
        let inset = insetScreen / pointsPerMapPoint

        struct Bucket {
            var count: Int
            var representative: MapMediaPoint
            var minLatitude: Double
            var maxLatitude: Double
            var minLongitude: Double
            var maxLongitude: Double
            var sumX: Double
            var sumY: Double
            var originX: Double
            var originY: Double
        }
        var buckets: [String: Bucket] = [:]

        for point in points {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ))
            let indexX = floor(mapPoint.x / cell)
            let indexY = floor(mapPoint.y / cell)
            let key = "\(Int(indexX))x\(Int(indexY))"
            if var bucket = buckets[key] {
                bucket.count += 1
                bucket.minLatitude = min(bucket.minLatitude, point.latitude)
                bucket.maxLatitude = max(bucket.maxLatitude, point.latitude)
                bucket.minLongitude = min(bucket.minLongitude, point.longitude)
                bucket.maxLongitude = max(bucket.maxLongitude, point.longitude)
                bucket.sumX += mapPoint.x
                bucket.sumY += mapPoint.y
                if isNewer(point, than: bucket.representative) {
                    bucket.representative = point
                }
                buckets[key] = bucket
            } else {
                buckets[key] = Bucket(
                    count: 1,
                    representative: point,
                    minLatitude: point.latitude,
                    maxLatitude: point.latitude,
                    minLongitude: point.longitude,
                    maxLongitude: point.longitude,
                    sumX: mapPoint.x,
                    sumY: mapPoint.y,
                    originX: indexX * cell,
                    originY: indexY * cell
                )
            }
        }

        return buckets.values
            .filter { bucket in
                let cellRect = MKMapRect(
                    x: bucket.originX,
                    y: bucket.originY,
                    width: cell,
                    height: cell
                )
                return rects.contains { $0.intersects(cellRect) }
            }
            .map { bucket in
                let count = Double(bucket.count)
                let clamped = MKMapPoint(
                    x: min(max(bucket.sumX / count, bucket.originX + inset), bucket.originX + cell - inset),
                    y: min(max(bucket.sumY / count, bucket.originY + inset), bucket.originY + cell - inset)
                ).coordinate
                return MapCluster(
                    count: bucket.count,
                    representativeId: bucket.representative.id,
                    latitude: clamped.latitude,
                    longitude: clamped.longitude,
                    bounds: GeoBounds(
                        minLatitude: bucket.minLatitude,
                        maxLatitude: bucket.maxLatitude,
                        minLongitude: bucket.minLongitude,
                        maxLongitude: bucket.maxLongitude
                    )
                )
            }
            .sorted { $0.representativeId < $1.representativeId }
    }

    // How wide a cell should be on screen. A view full of photos then
    // holds about six cells, and a cell is always roomier than one tile.
    static func targetCellSize(for viewSize: CGSize, tileSize: CGFloat = MapClusterTile.size) -> CGFloat {
        let fromDensity = sqrt(viewSize.width * viewSize.height / 6)
        return max(fromDensity, tileSize + tileGap)
    }

    // The world-aligned cell for this zoom. It is a power-of-two slice
    // of the world, and the largest one that is still at least
    // `targetCellSize` points wide on screen.
    static func cellMapSize(
        visibleMapRect: MKMapRect,
        viewSize: CGSize,
        tileSize: CGFloat = MapClusterTile.size
    ) -> Double {
        guard viewSize.width > 0, visibleMapRect.width > 0 else {
            return MKMapRect.world.width
        }
        let target = Double(targetCellSize(for: viewSize, tileSize: tileSize))
        let pointsPerMapPoint = Double(viewSize.width) / visibleMapRect.width
        guard target > 0, pointsPerMapPoint.isFinite, pointsPerMapPoint > 0 else {
            return MKMapRect.world.width
        }
        var cell = MKMapRect.world.width
        while cell > 1 {
            let half = cell / 2
            if half * pointsPerMapPoint >= target {
                cell = half
            } else {
                break
            }
        }
        return cell
    }

    // Prefers the later capture, then the greater id, so a tie still
    // picks the same tile photo every time the map reclusters.
    private static func isNewer(_ point: MapMediaPoint, than other: MapMediaPoint) -> Bool {
        if point.takenAt != other.takenAt {
            return point.takenAt > other.takenAt
        }
        return point.id > other.id
    }

    // MapKit expresses a dateline-crossing view as a rectangle that runs
    // past the eastern edge of the world. Split that into the two pieces
    // that actually contain photos.
    private static func wrappedRects(for mapRect: MKMapRect) -> [MKMapRect] {
        let world = MKMapRect.world
        let minY = max(mapRect.minY, world.minY)
        let maxY = min(mapRect.maxY, world.maxY)
        guard maxY > minY, mapRect.width > 0 else { return [] }
        let height = maxY - minY
        let worldWidth = world.width
        let width = min(mapRect.width, worldWidth)
        var originX = mapRect.minX.truncatingRemainder(dividingBy: worldWidth)
        if originX < 0 {
            originX += worldWidth
        }
        if originX + width <= worldWidth {
            return [MKMapRect(x: originX, y: minY, width: width, height: height)]
        }
        let firstWidth = worldWidth - originX
        return [
            MKMapRect(x: originX, y: minY, width: firstWidth, height: height),
            MKMapRect(x: 0, y: minY, width: width - firstWidth, height: height),
        ]
    }
}
