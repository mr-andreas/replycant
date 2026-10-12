import CoreLocation
import MapKit
import SwiftUI

// Identifies the cluster a person tapped so the place grid can query the
// same box the tile counted, and so a second tap still pushes a screen.
struct PlaceSelection: Hashable {
    let bounds: GeoBounds
    let latitude: Double
    let longitude: Double
    let token: UUID
}

// Shows the library as place tiles. Zooming changes how large a "place"
// is, and tapping a tile opens just the photos that tile counted.
struct PlacesMapView: View {
    @StateObject private var timelineManager: TimelineManager
    @StateObject private var tileImages: MapTileImages
    @State private var points: [MapMediaPoint] = []
    @State private var clusters: [MapCluster] = []
    @State private var itemsById: [String: TimelineItem] = [:]
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: PlaceSelection?
    @State private var didFrame = false
    @State private var lastRect: MKMapRect?
    @State private var lastSize: CGSize?
    @State private var clusterGeneration = 0

    // The tile photo store shares the map's timeline manager so it can
    // reuse a local photo before downloading one.
    init() {
        let timelineManager = TimelineManager(scope: .geotagged)
        _timelineManager = StateObject(wrappedValue: timelineManager)
        _tileImages = StateObject(wrappedValue: MapTileImages(
            loadImage: MapTileImages.loading(with: timelineManager)
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if timelineManager.isLoading && points.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = timelineManager.errorMessage, points.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load the map",
                        systemImage: "map",
                        description: Text(error)
                    )
                } else if points.isEmpty {
                    ContentUnavailableView(
                        "No photos with location",
                        systemImage: "mappin.slash",
                        description: Text("Photos with a location will show up here.")
                    )
                } else {
                    map
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selection) { selection in
                PlaceTimelineView(selection: selection)
            }
        }
        .task {
            await timelineManager.loadTimeline()
            await reloadPoints(resetCamera: true)
        }
        .onReceive(timelineManager.contentDidChange) { _ in
            Task { await reloadPoints(resetCamera: false) }
        }
    }

    private var map: some View {
        GeometryReader { geo in
            // Pitch and rotation change the visible rect's size while
            // panning, which would regroup photos. Pan and zoom keep it fixed.
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                ForEach(clusters, id: \.representativeId) { cluster in
                    Annotation(
                        "",
                        coordinate: CLLocationCoordinate2D(
                            latitude: cluster.latitude,
                            longitude: cluster.longitude
                        )
                    ) {
                        Button {
                            selection = PlaceSelection(
                                bounds: cluster.bounds,
                                latitude: cluster.latitude,
                                longitude: cluster.longitude,
                                token: UUID()
                            )
                        } label: {
                            MapClusterTile(
                                count: cluster.count,
                                image: tileImages.images[cluster.representativeId]
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cluster.count) photos")
                    }
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange(frequency: .onEnd) { context in
                lastRect = context.rect
                lastSize = geo.size
                recluster(rect: context.rect, size: geo.size)
            }
        }
    }

    // Reloads coordinates after the first open and after a sync. The
    // camera is framed once so a later upload does not yank the map.
    private func reloadPoints(resetCamera: Bool) async {
        guard let loaded = try? await timelineManager.loadGeotaggedPoints() else { return }
        points = loaded
        if resetCamera || !didFrame {
            camera = Self.cameraFraming(loaded)
            didFrame = true
        }
        if let lastRect, let lastSize {
            recluster(rect: lastRect, size: lastSize)
        }
    }

    // Reclusters off the main thread and ignores a result that a newer
    // camera change has already superseded.
    private func recluster(rect: MKMapRect, size: CGSize) {
        clusterGeneration += 1
        let generation = clusterGeneration
        let snapshot = points
        Task.detached(priority: .userInitiated) {
            let next = MapClusterer.clusters(
                from: snapshot,
                visibleMapRect: rect,
                viewSize: size
            )
            await MainActor.run {
                guard generation == clusterGeneration else { return }
                clusters = next
                Task { await loadRepresentatives(for: next) }
            }
        }
    }

    // Fetches only the photos newly visible as tiles. Already loaded
    // photos stay so panning back does not flash empty tiles.
    private func loadRepresentatives(for clusters: [MapCluster]) async {
        let missing = clusters.map(\.representativeId).filter { itemsById[$0] == nil }
        guard !missing.isEmpty else { return }
        guard let items = try? await timelineManager.loadItems(ids: missing) else { return }
        for item in items {
            itemsById[item.id] = item
        }
        tileImages.load(items)
    }

    // Frames every placed photo with a little margin, and keeps a single
    // photo from zooming in so far that the map is useless.
    private static func cameraFraming(_ points: [MapMediaPoint]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for point in points.dropFirst() {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.08),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.08)
        )
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

// Draws one place tile. The count is the number of photos the place grid
// will show, matching the Apple Photos map.
struct MapClusterTile: View {
    // Shared with the clusterer so a tile is kept inside its cell.
    static let size: CGFloat = 84

    let count: Int
    let image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.35)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipped()

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white, lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
    }
}
