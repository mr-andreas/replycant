import UIKit
import LibGit2

/// Session-scoped cache and preloader for fullscreen image viewing.
/// Owned by `FullScreenMediaPageViewController` so all cached originals
/// are released when the user dismisses fullscreen. Preloads run
/// sequentially in outward-symmetric order (+1, -1, +2, -2, ...) and
/// are cancelled/restarted on each swipe so the nearest neighbors of
/// the new center always have priority.
@MainActor
final class FullScreenImagePreloader {

    private let cache: ImageCacheWrapper
    private var preloadTask: Task<Void, Never>?

    init() {
        // 500 MB is generous for a handful of full-res photos; LRU
        // eviction keeps memory bounded if the user swipes far.
        cache = ImageCacheWrapper(maxMemoryMB: 500)
    }

    func cachedImage(for id: String) -> UIImage? {
        cache.get(for: id)
    }

    func store(_ image: UIImage, for id: String) {
        cache.set(image, for: id)
    }

    /// Kicks off ordered preloading around the currently viewed item.
    /// Cancels any in-flight preload run so the new neighbors take
    /// priority immediately.
    func preload(
        around itemId: String,
        in items: [TimelineItem],
        radius: Int,
        photoLibrary: PhotoLibraryProviding,
        repository: Repository,
        lfsClient: GitLFS
    ) {
        preloadTask?.cancel()
        guard radius > 0 else { return }

        guard let currentIndex = items.firstIndex(where: { $0.id == itemId }) else { return }

        let indices = FullScreenPreloadOrder.neighborIndices(
            currentIndex: currentIndex, count: items.count, radius: radius
        )

        preloadTask = Task {
            for index in indices {
                guard !Task.isCancelled else { return }

                let item = items[index]

                if item.original.spec.mediaType == "video" { continue }
                if cache.get(for: item.id) != nil { continue }

                do {
                    let image = try await FullResolutionImageLoader.loadOriginalImage(
                        for: item,
                        priority: .fullscreenNeighbor,
                        repository: repository,
                        lfsClient: lfsClient,
                        photoLibrary: photoLibrary
                    )
                    guard !Task.isCancelled else { return }
                    cache.set(image, for: item.id)
                    logDebug("Preloaded fullscreen image for \(item.id)", context: "Preload")
                } catch is CancellationError {
                    return
                } catch {
                    logDebug("Preload failed for \(item.id): \(error.localizedDescription)", context: "Preload")
                }
            }
        }
    }
}
