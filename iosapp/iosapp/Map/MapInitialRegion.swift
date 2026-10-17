import CoreLocation
import MapKit

// Picks the map's first view from the library's own coordinates, so a
// few trips abroad do not open the map on the whole world. No device
// location is used.
enum MapInitialRegion {
    // A country-sized window. Photos outside it are still on the map;
    // they just do not decide the opening zoom.
    private static let windowDegrees = 12.0
    private static let margin = 1.4
    private static let minimumSpan = 0.08

    // The opening region for a set of geotagged photos. Nil when none
    // of the coordinates are usable, so the caller can leave the camera
    // automatic.
    static func region(for points: [MapMediaPoint]) -> MKCoordinateRegion? {
        let valid = points.filter(isUsable)
        guard let anchor = densestCell(in: valid) else { return nil }

        let anchorLatitude = Double(anchor.latitude) + 0.5
        let anchorLongitude = Double(anchor.longitude) + 0.5
        let halfWindow = windowDegrees / 2

        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude
        var included = false

        for point in valid {
            let latitudeOffset = point.latitude - anchorLatitude
            let longitudeOffset = normalizedDelta(
                point.longitude,
                relativeTo: anchorLongitude
            )
            guard abs(latitudeOffset) <= halfWindow,
                  abs(longitudeOffset) <= halfWindow else { continue }
            included = true
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, longitudeOffset)
            maxLongitude = max(maxLongitude, longitudeOffset)
        }
        guard included else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: normalize(anchorLongitude + (minLongitude + maxLongitude) / 2)
        )
        let span = MKCoordinateSpan(
            latitudeDelta: clampedSpan(maxLatitude - minLatitude),
            longitudeDelta: clampedSpan(maxLongitude - minLongitude)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // Null Island and out-of-range values show up in bad metadata and
    // would otherwise pull the opening view across the globe.
    private static func isUsable(_ point: MapMediaPoint) -> Bool {
        let latitude = point.latitude
        let longitude = point.longitude
        guard latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            return false
        }
        return latitude != 0 || longitude != 0
    }

    // One degree of latitude and longitude. The densest cell is the
    // library's home, and a country-sized window is measured from it.
    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    // The cell holding the most photos. An equal count goes to the cell
    // with the newest photo, then farther south and west, so the opening
    // view does not depend on query order.
    private static func densestCell(in points: [MapMediaPoint]) -> Cell? {
        struct Bucket {
            var count: Int
            var newest: Date
        }
        var buckets: [Cell: Bucket] = [:]
        for point in points {
            let cell = Cell(
                latitude: Int(floor(point.latitude)),
                longitude: Int(floor(point.longitude))
            )
            if var bucket = buckets[cell] {
                bucket.count += 1
                if point.takenAt > bucket.newest {
                    bucket.newest = point.takenAt
                }
                buckets[cell] = bucket
            } else {
                buckets[cell] = Bucket(count: 1, newest: point.takenAt)
            }
        }
        return buckets.max { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count < rhs.value.count
            }
            if lhs.value.newest != rhs.value.newest {
                return lhs.value.newest < rhs.value.newest
            }
            if lhs.key.latitude != rhs.key.latitude {
                return lhs.key.latitude < rhs.key.latitude
            }
            return lhs.key.longitude < rhs.key.longitude
        }?.key
    }

    // Pads the photos a little, but never tighter than a neighborhood
    // or wider than the country window that selected them.
    private static func clampedSpan(_ extent: Double) -> Double {
        min(max(extent * margin, minimumSpan), windowDegrees)
    }

    // Shortest signed difference, so a photo just west of the dateline
    // is a neighbor of one just east of it.
    private static func normalizedDelta(
        _ longitude: Double,
        relativeTo anchor: Double
    ) -> Double {
        var delta = longitude - anchor
        while delta > 180 {
            delta -= 360
        }
        while delta < -180 {
            delta += 360
        }
        return delta
    }

    // Folds a longitude that the dateline window shifted past ±180 back
    // into the range MapKit expects.
    private static func normalize(_ longitude: Double) -> Double {
        var value = longitude
        while value > 180 {
            value -= 360
        }
        while value < -180 {
            value += 360
        }
        return value
    }
}
