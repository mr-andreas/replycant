import SwiftUI

// Keeps each place tile's photo outside the map annotation. MapKit
// reuses those annotation views, so a loader stored on the tile itself
// can keep showing a photo from a place the tile used to represent.
@MainActor
final class MapTileImages: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]

    private var inFlight: Set<String> = []
    private let loadImage: (TimelineItem) async -> UIImage?

    init(loadImage: @escaping (TimelineItem) async -> UIImage?) {
        self.loadImage = loadImage
    }

    // Starts one load per photo that is not already shown or already
    // loading. The result is stored under that photo's id so a recycled
    // tile can only draw the image for its current representative.
    func load(_ items: [TimelineItem]) {
        for item in items {
            guard images[item.id] == nil, !inFlight.contains(item.id) else { continue }
            inFlight.insert(item.id)
            let loadImage = self.loadImage
            Task {
                let image = await loadImage(item)
                inFlight.remove(item.id)
                if let image {
                    images[item.id] = image
                }
            }
        }
    }

    // Uses the same local-library-then-download path as the timeline, so
    // a tile never fetches a photo the phone already has.
    static func loading(
        with timelineManager: TimelineManager
    ) -> (TimelineItem) async -> UIImage? {
        { item in
            await withCheckedContinuation { continuation in
                let box = ImageLoaderBox()
                let loader = ImageLoader(
                    item: item,
                    priority: .timelineViewport,
                    timelineManager: timelineManager
                ) { didRender in
                    let image = didRender ? box.loader?.image : nil
                    box.loader = nil
                    continuation.resume(returning: image)
                }
                box.loader = loader
                loader.loadImage()
            }
        }
    }
}

// Holds the loader until its photo arrives. The loader's own callback
// is what keeps it alive, and clearing the box afterwards lets it go.
private final class ImageLoaderBox {
    var loader: ImageLoader?
}
