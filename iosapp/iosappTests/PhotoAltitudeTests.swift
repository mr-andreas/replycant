import CoreLocation
import Testing
@testable import iosapp

// PhotoKit reports 0 meters when a fix has no altitude. Details print
// every stored altitude, so that 0 has to be left out while a real
// sea-level reading stays.
struct PhotoAltitudeTests {
    @Test func missingAltitudeIsOmitted() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 59.3, longitude: 18.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        #expect(MediaMetadata.Location.altitudeMeters(from: location) == nil)
    }

    // Sea level is a real altitude of 0. Core Location marks it with a
    // non-negative vertical accuracy, unlike a fix that has no altitude.
    @Test func seaLevelAltitudeIsKept() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 59.3, longitude: 18.0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        #expect(MediaMetadata.Location.altitudeMeters(from: location) == 0)
    }

    @Test func measuredAltitudeIsKept() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 59.3, longitude: 18.0),
            altitude: 123.4,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        #expect(MediaMetadata.Location.altitudeMeters(from: location) == 123.4)
    }
}
