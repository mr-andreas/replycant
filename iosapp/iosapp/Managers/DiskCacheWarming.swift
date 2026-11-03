import Foundation
import GitDB
import LibGit2

// One thumbnail chosen for the disk cache. The path is the LFS
// pointer the warmer downloads when the bytes are not already stored.
struct DiskCacheWarmRequest: Equatable, Sendable {
    let itemId: String
    let lfsPath: String
}

// Fills a disk-cache tier with the newest thumbnails. The open
// timeline and a charging wake share this choice, so the first screen
// is the same set of images either way.
@MainActor
enum DiskCacheWarming {
    // Downloads the newest page one thumbnail at a time. Stops between
    // items when the wake is cancelled, and skips a download that fails
    // so one missing file does not drop the rest of the page.
    static func warmNewest(
        itemCount: Int,
        scope: TimelineScope,
        loader: ManifestLoaderProtocol,
        isCancelled: () -> Bool = { Task.isCancelled },
        warmOne: (DiskCacheWarmRequest) async throws -> Void
    ) async {
        do {
            guard itemCount > 0 else { return }
            let total = try await loader.countTimelineOriginals(scope: scope)
            guard total > 0 else { return }
            let offset = max(0, total - itemCount)
            let limit = min(itemCount, total)
            let originals = try await loader.loadTimelinePage(
                offset: offset,
                limit: limit,
                scope: scope
            )
            if isCancelled() { return }
            let refs = originals.map(originalRef(for:))
            let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
            if isCancelled() { return }

            for original in originals {
                if isCancelled() { return }
                guard let request = request(for: original, thumbnails: thumbnails) else {
                    continue
                }
                do {
                    try await warmOne(request)
                } catch is CancellationError {
                    return
                } catch {
                    logDebug(
                        "Disk cache warm failed for \(request.itemId): \(error.localizedDescription)",
                        context: "Cache"
                    )
                }
            }
            logDebug(
                "Disk cache warm finished for \(originals.count) items",
                context: "Cache"
            )
        } catch is CancellationError {
            return
        } catch {
            logDebug(
                "Disk cache warm error: \(error.localizedDescription)",
                context: "Cache"
            )
        }
    }

    // Warms the top tier from the on-device library. A charging wake
    // has no timeline view, which is the only other place that does this.
    // The refresh is recorded only after the library is open, so a wake
    // that never gets that far does not appear on the Cache page.
    static func warmTopCacheFromLibrary() async {
        if Task.isCancelled { return }
        do {
            guard let lfsUrl = ServerConfigurationManager.shared.loadLFSURL(),
                  !lfsUrl.isEmpty else {
                logDebug(
                    "Skipping top-cache warm because LFS is not configured",
                    context: "Cache"
                )
                return
            }
            let repository = try RepositoryManager.shared.getRepository()
            let lfsClient = GitLFS(
                serverURL: lfsUrl,
                clientIdentity: ClientIdentityManager.shared.loadSecIdentity(),
                pinnedCA: ServerConfigurationManager.shared.loadSecCertificate()
            )
            let database = try ManifestLoaderManager.shared.getDatabase()
            let registry = ManifestLoaderManager.shared.getRegistry()
            let loader = DefaultManifestManager(
                repository: repository,
                deviceSpace: DeviceIdentifierManager.shared.deviceSpaceIdentifier,
                lfsClient: lfsClient,
                database: database,
                registry: registry
            )
            await TopCacheRefreshLog.shared.record(source: .charging) {
                await warmNewest(
                    itemCount: CacheSettingsManager.shared.topCacheWarmItemCount,
                    scope: .all,
                    loader: loader
                ) { request in
                    try await ImageDiskCacheManager.shared.warmTop(
                        priority: .topWarm,
                        itemId: request.itemId,
                        lfsPath: request.lfsPath,
                        repository: repository,
                        lfsClient: lfsClient
                    )
                }
            }
        } catch {
            logDebug(
                "Top-cache warm could not open the library: \(error.localizedDescription)",
                context: "Cache"
            )
        }
    }

    private static func originalRef(for original: OriginalManifest) -> String {
        "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
    }

    // The 225px variant is what the grid draws on a phone. A library
    // that only has a smaller thumbnail still needs something cached.
    private static func displayThumbnail(
        in thumbnailSet: ThumbnailSetManifest
    ) -> ThumbnailSetManifest.Spec.Entry? {
        let sorted = thumbnailSet.spec.thumbnails.sorted { $0.width < $1.width }
        return sorted.first { $0.width >= 225 } ?? sorted.last
    }

    private static func request(
        for original: OriginalManifest,
        thumbnails: [String: ThumbnailSetManifest]
    ) -> DiskCacheWarmRequest? {
        let ref = originalRef(for: original)
        guard let thumbnailSet = thumbnails[ref],
              let entry = displayThumbnail(in: thumbnailSet) else {
            return nil
        }
        let deviceSpace = thumbnailSet.metadata.deviceSpace
        let path = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(entry.name))"
        return DiskCacheWarmRequest(itemId: original.spec.id, lfsPath: path)
    }
}
