import CoreLocation
import SwiftUI

// Shows the timeline grid for one map tile. The manager is scoped to the
// tile's bounds, so paging and the month sidebar stay inside that place.
struct PlaceTimelineView: View {
    let selection: PlaceSelection
    @StateObject private var timelineManager: TimelineManager
    @State private var placeName = "Places"

    init(selection: PlaceSelection) {
        self.selection = selection
        _timelineManager = StateObject(
            wrappedValue: TimelineManager(scope: .area(selection.bounds))
        )
    }

    var body: some View {
        TimelineGridScreen(
            timelineManager: timelineManager,
            emptyTitle: "No photos here",
            emptyMessage: "None of the photos from this place are available."
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(placeName)
                        .font(.headline)
                    Text("\(timelineManager.totalCount) Items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task {
            await resolvePlaceName()
        }
    }

    // Names the place from the cluster center. Coordinates leave the
    // device for this lookup; if it fails, the screen stays "Places".
    private func resolvePlaceName() async {
        let location = CLLocation(latitude: selection.latitude, longitude: selection.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return
        }
        placeName = placemark.locality
            ?? placemark.subLocality
            ?? placemark.name
            ?? placemark.country
            ?? "Places"
    }
}
