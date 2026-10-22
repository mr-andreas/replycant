import Foundation
import LibGit2
import CryptoKit
import UIKit
import Combine
import GitDB

// Abstracts idle timer control so upload lock-screen behavior is testable.
protocol IdleTimerControlling {
    var isIdleTimerDisabled: Bool { get set }
}

// Bridges sync lifecycle to UIApplication idle timer to keep uploads alive.
struct UIApplicationIdleTimerController: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

enum PhotoSyncError: Error {
    case repositoryNotFound
    case lfsUrlNotConfigured
    case syncInProgress
}

// Tells the upload tab why a Wi-Fi upload stopped, and that pressing
// Start Upload again is how to continue. Already-uploaded items are skipped.
struct UploadPausedOnMobileDataError: Error, LocalizedError {
    var errorDescription: String? {
        "Upload paused because the phone switched to mobile data. Press Start Upload to continue."
    }
}

// Carries the already-computed user guidance so the upload tab can
// show the same copy as the incompatibility banner.
private struct UploadRefusedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Background runs upload small files first. A manual upload keeps the
// library's newest-first order.
enum UploadOrder: Sendable {
    case newestFirst
    case smallestFirst
}

enum SyncState: Equatable {
    case idle
    case syncing(current: Int, total: Int, currentFile: String, uploadSpeed: String, fileSize: String)
    case completed(total: Int)
    case failed(Error)
    
    static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case let (
            .syncing(current: lCurrent, total: lTotal, currentFile: lCurrentFile, uploadSpeed: lUploadSpeed, fileSize: lFileSize),
            .syncing(current: rCurrent, total: rTotal, currentFile: rCurrentFile, uploadSpeed: rUploadSpeed, fileSize: rFileSize)
        ):
            return lCurrent == rCurrent &&
                lTotal == rTotal &&
                lCurrentFile == rCurrentFile &&
                lUploadSpeed == rUploadSpeed &&
                lFileSize == rFileSize
        case (.completed(let l), .completed(let r)):
            return l == r
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

@MainActor
final class PhotoSyncManager: ObservableObject {
    // The Upload tab and a background run share one upload so they cannot
    // run at the same time, and opening the app shows the run in progress.
    static let shared = PhotoSyncManager()

    @Published var syncState: SyncState = .idle
    @Published var isSyncing = false
    
    private let photoLibrary: PhotoLibraryProviding
    private let uploadedMediaCache: UploadedMediaCaching
    private let networkCost: NetworkCostProviding
    private var idleTimer: IdleTimerControlling
    var syncTask: Task<Void, Never>?
    // Preserves caller-injected test doubles so global invalidation broadcasts
    // cannot swap tests onto production networking paths mid-sync.
    private let injectedManifestManager: ManifestManager?
    // Caches lazily constructed production dependencies until config changes or
    // database replacement broadcasts require a fresh instance.
    private var cachedManifestManager: ManifestManager?
    private var syncGeneration: UInt64 = 0
    // Remembers a run the user already accepted on mobile data, so a later
    // path change does not cancel a transfer they chose to pay for.
    private var startedOnMeteredNetwork = false
    private var networkCostCancellable: AnyCancellable?
    // Observes LFS endpoint changes so subsequent syncs rebuild clients with the updated server URL.
    private var lfsURLObserver: AnyCancellable?
    // Observes replacement of the shared manifest database so syncs never write through a discarded instance.
    private var databaseInvalidationObserver: AnyCancellable?
    // Cleared when an upload finishes so a caught-up library does not keep
    // a 7-day reminder.
    private let backlogTracker: UploadBacklogTracking
    
    // Injects dependencies so sync behavior can be exercised in tests.
    init(
        photoLibraryProvider: PhotoLibraryProviding = PhotoLibraryManager(),
        manifestManager: ManifestManager? = nil,
        uploadedMediaCache: UploadedMediaCaching = UploadedMediaCache.shared,
        idleTimer: IdleTimerControlling = UIApplicationIdleTimerController(),
        networkCost: NetworkCostProviding = NetworkCostMonitor.shared,
        backlogTracker: UploadBacklogTracking? = nil
    ) {
        self.photoLibrary = photoLibraryProvider
        self.injectedManifestManager = manifestManager
        self.uploadedMediaCache = uploadedMediaCache
        self.idleTimer = idleTimer
        self.networkCost = networkCost
        self.backlogTracker = backlogTracker ?? UploadBacklogTracker.shared
        observeLFSURLChanges()
        observeDatabaseInvalidation()
        observeNetworkCost()
    }

    // Lets the upload button decide whether to warn before any bytes move.
    var isOnMeteredNetwork: Bool { networkCost.isMetered }

    // Asks for photo access while the app is open. A background run cannot
    // show the system prompt, so the toggle does this before enabling itself.
    func requestPhotoAccess() async -> Bool {
        await photoLibrary.requestAuthorization()
    }

    // Recreates manifest dependencies lazily, letting each sync run pick up the latest configured LFS endpoint.
    func getManifestManager() throws -> ManifestManager {
        if let manifestManager = injectedManifestManager {
            return manifestManager
        }
        if let manifestManager = cachedManifestManager {
            return manifestManager
        }
        
        guard let lfsUrl = ServerConfigurationManager.shared.loadLFSURL(), !lfsUrl.isEmpty else {
            logError("LFS URL not configured", context: "PhotoSync")
            throw PhotoSyncError.lfsUrlNotConfigured
        }
        
        let repository: Repository
        do {
            repository = try RepositoryManager.shared.getRepository()
        } catch {
            logError("Repository not found at: \(RepositoryManager.shared.repositoryPath())", context: "PhotoSync")
            throw PhotoSyncError.repositoryNotFound
        }
        
        log("Using repository at: \(RepositoryManager.shared.repositoryPath())", context: "PhotoSync")
        log("Using LFS server: \(lfsUrl)", context: "PhotoSync")
        
        let lfsClient = GitLFS(
            serverURL: lfsUrl,
            clientIdentity: ClientIdentityManager.shared.loadSecIdentity(),
            pinnedCA: ServerConfigurationManager.shared.loadSecCertificate()
        )
        
        // Initializes manifest manager with database-backed reads and git-first write orchestration.
        let deviceSpace = DeviceIdentifierManager.shared.deviceSpaceIdentifier
        let database = try ManifestLoaderManager.shared.getDatabase()
        let registry = ManifestLoaderManager.shared.getRegistry()
        self.cachedManifestManager = DefaultManifestManager(
            repository: repository,
            deviceSpace: deviceSpace,
            lfsClient: lfsClient,
            database: database,
            registry: registry
        )
        
        return self.cachedManifestManager!
    }

    // Subscribes to LFS URL changes so stale upload/download dependencies are dropped after repository settings updates.
    private func observeLFSURLChanges() {
        lfsURLObserver = NotificationCenter.default.publisher(for: ServerConfigurationManager.lfsURLDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleLFSURLDidChange()
            }
    }

    // Discards cached manifest state so the next sync uses a freshly constructed GitLFS client.
    private func handleLFSURLDidChange() {
        cachedManifestManager = nil
    }

    // Drops the cached manifest manager when the shared database is replaced,
    // so a sync started after a reset writes to the live database rather than a
    // discarded instance whose rows nothing else will ever read.
    private func observeDatabaseInvalidation() {
        databaseInvalidationObserver = NotificationCenter.default
            .publisher(for: ManifestLoaderManager.databaseDidInvalidateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cachedManifestManager = nil
            }
    }
    
    // Stops a Wi-Fi upload that walks onto mobile data, including the file
    // currently in flight, so the phone does not keep spending data.
    private func observeNetworkCost() {
        networkCostCancellable = networkCost.isMeteredPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isMetered in
                guard isMetered else { return }
                Task { @MainActor in
                    self?.stopForMeteredNetwork()
                }
            }
    }

    // Ignores the transition unless this run began on Wi-Fi and is still
    // moving bytes. A confirmed mobile-data upload is left alone.
    private func stopForMeteredNetwork() {
        guard isSyncing, !startedOnMeteredNetwork else { return }
        log("Pausing upload because the network became metered", context: "PhotoSync")
        stopSync(finalState: .failed(UploadPausedOnMobileDataError()))
    }

    // Starts a new sync run and stamps it with a generation token so stale callbacks cannot update UI state.
    // Manual upload keeps newest-first. Background upload passes smallest-first
    // so a short charging window finishes as many files as it can.
    func startSync(order: UploadOrder = .newestFirst) async {
        guard !isSyncing else {
            logWarning("Sync already in progress, ignoring request", context: "PhotoSync")
            return
        }
        startedOnMeteredNetwork = networkCost.isMetered
        
        if let incompatibility = DatabaseCompatibilityManager.shared.incompatibility {
            logError("Refusing upload because the database format is incompatible", context: "PhotoSync")
            setSyncState(.failed(UploadRefusedError(message: incompatibility.userMessage)))
            return
        }

        log("Starting sync process...", context: "PhotoSync")
        syncGeneration += 1
        let generation = syncGeneration
        setSyncState(.syncing(current: 0, total: 0, currentFile: "Asking for photo access...", uploadSpeed: "", fileSize: ""))
        
        syncTask = Task {
            do {
                // A wake rebuild may still be replacing the node. Waiting
                // here keeps the upload off a proxy iOS dropped while the
                // phone was locked.
                try await TailnetBootstrap.shared.ensureJoinedIfConfigured()

                log("Requesting photo library authorization...", context: "PhotoSync")
                guard await photoLibrary.requestAuthorization() else {
                    logError("Photo library access denied", context: "PhotoSync")
                    throw PhotoLibraryError.accessDenied
                }

                await updateState(
                    .syncing(current: 0, total: 0, currentFile: "Scanning your library...", uploadSpeed: "", fileSize: ""),
                    generation: generation
                )
                
                log("Fetching all assets from photo library...", context: "PhotoSync")
                let assets = try await loadAssets()
                
                guard !assets.isEmpty else {
                    log("No assets found, completing sync", context: "PhotoSync")
                    await updateState(.completed(total: 0), generation: generation)
                    return
                }
                
                log("Starting sync of \(assets.count) assets...", context: "PhotoSync")
                let syncedCount = try await syncAssets(assets, generation: generation, order: order)
                log("Sync completed successfully! Total: \(syncedCount) assets", context: "PhotoSync")
                await updateState(.completed(total: syncedCount), generation: generation)
            } catch {
                logError("Sync failed with error: \(error.localizedDescription)", context: "PhotoSync")
                DatabaseCompatibilityManager.shared.reportIfVersionError(error)
                await updateState(.failed(error), generation: generation)
            }
        }
    }
    
    // Cancels the active run and invalidates its generation so late callbacks are ignored.
    func cancelSync() {
        log("Cancelling sync...", context: "PhotoSync")
        stopSync(finalState: .idle)
        log("Sync cancelled", context: "PhotoSync")
    }

    // Shared by the user cancel and the mobile-data stop so both abort the
    // in-flight file and ignore progress from the abandoned generation.
    private func stopSync(finalState: SyncState) {
        syncGeneration += 1
        injectedManifestManager?.cancelActiveLFSUpload()
        cachedManifestManager?.cancelActiveLFSUpload()
        syncTask?.cancel()
        syncTask = nil
        setSyncState(finalState)
    }
    
    // Encrypts and uploads assets while preserving plaintext integrity hashes in manifests for post-decryption verification.
    private func syncAssets(
        _ assets: [PhotoAsset],
        generation: UInt64,
        order: UploadOrder
    ) async throws -> Int {
        let deviceSpace = DeviceIdentifierManager.shared.deviceSpaceIdentifier
        let modificationDateFormatter = ISO8601DateFormatter()
        var cacheSkippedCount = 0
        var assetsRequiringDatabaseChecks: [(asset: PhotoAsset, modifiedAt: String?)] = []
        for asset in assets {
            let modifiedAt = asset.modificationDate.map { modificationDateFormatter.string(from: $0) }
            if uploadedMediaCache.contains(localID: asset.id, modifiedAt: modifiedAt) {
                cacheSkippedCount += 1
                continue
            }
            assetsRequiringDatabaseChecks.append((asset: asset, modifiedAt: modifiedAt))
        }
        guard !assetsRequiringDatabaseChecks.isEmpty else {
            log("All assets skipped by uploaded media cache", context: "PhotoSync")
            return 0
        }
        if order == .smallestFirst {
            assetsRequiringDatabaseChecks = await orderSmallestFirst(assetsRequiringDatabaseChecks)
        }

        let repository = try RepositoryManager.shared.getRepository()
        do {
            try DatabaseVersion.requireSupportedIfHeadExists(in: repository)
        } catch let error as DatabaseVersionError {
            DatabaseCompatibilityManager.shared.report(error)
            throw error
        }
        let kekManager = KEKEpochManager(repository: repository)
        let activeKEK = try kekManager.loadCurrentKEK()
        let manager = try getManifestManager()

        // Syncs cache to HEAD once before upload so dedup checks include latest pulled/committed manifests.
        try await manager.syncToHead(progressHandler: nil)
        let uploadedByLocalID = try await manager.loadUploadedLocalIDs()
        var dbSkippedCount = 0
        
        for (loopIndex, entry) in assetsRequiringDatabaseChecks.enumerated() {
            let asset = entry.asset
            let assetModifiedAt = entry.modifiedAt
            if Task.isCancelled {
                log("Task cancelled at asset \(loopIndex + 1) of \(assetsRequiringDatabaseChecks.count)", context: "PhotoSync")
                break
            }
            
            log("Processing asset \(loopIndex + 1)/\(assetsRequiringDatabaseChecks.count): \(asset.id)", context: "PhotoSync")

            if let localIDEntry = uploadedByLocalID.index(forKey: asset.id) {
                let uploadedModifiedAt = uploadedByLocalID[localIDEntry].value
                if uploadedModifiedAt == assetModifiedAt {
                    log("Original already exists by localID, skipping: \(asset.id)", context: "PhotoSync")
                    uploadedMediaCache.markConfirmed(localID: asset.id, modifiedAt: assetModifiedAt)
                    dbSkippedCount += 1
                    continue
                }
            }
            
            let normalizedName = normalizeObjectName(asset.id)
            
            log("Resolving asset file URL...", context: "PhotoSync")
            let assetFileURL = try await photoLibrary.getAssetFileURL(for: asset)
            defer { cleanupTemporaryUploadFileIfNeeded(assetFileURL) }

            let dek = EncryptionUtils.randomKey(length: 32)
            log("Computing streaming hashes...", context: "PhotoSync")
            let hashes = try await hashAsset(fileURL: assetFileURL, dek: dek)
            let sha256String = hashes.plaintextSHA256
            log("Calculated SHA256: \(sha256String)", context: "PhotoSync")

            // Deduplicates by content hash so renamed or cross-device duplicates are skipped.
            if try await manager.loadOriginalBySHA256(sha256String) != nil {
                log("Original already exists by SHA256, skipping: \(asset.id)", context: "PhotoSync")
                uploadedMediaCache.markConfirmed(localID: asset.id, modifiedAt: assetModifiedAt)
                dbSkippedCount += 1
                continue
            }

            let filename = photoLibrary.filename(for: asset)
            let uploadAsset = PhotoAsset(
                id: asset.id,
                phAsset: asset.phAsset,
                filename: filename,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                mediaType: asset.mediaType
            )
            
            let fileSize = formatBytes(Int(clamping: hashes.plaintextSize))
            await updateState(
                .syncing(
                    current: loopIndex + 1 - dbSkippedCount,
                    total: assetsRequiringDatabaseChecks.count - dbSkippedCount,
                    currentFile: uploadAsset.filename,
                    uploadSpeed: "Preparing...",
                    fileSize: fileSize
                ),
                generation: generation
            )
            
            log("Extracting metadata...", context: "PhotoSync")
            let metadata = photoLibrary.extractMetadata(for: uploadAsset)
            
            let location: OriginalManifest.Spec.Location?
            if let metaLocation = metadata.location {
                location = OriginalManifest.Spec.Location(
                    latitude: metaLocation.latitude,
                    longitude: metaLocation.longitude,
                    altitude: metaLocation.altitude
                )
            } else {
                location = nil
            }
            
            // Parse dates for the new fields
            let dateFormatter = ISO8601DateFormatter()
            let takenAt = metadata.takenAt.flatMap { dateFormatter.date(from: $0) }
            let clientCTime = asset.creationDate
            
            // Calculate guessedTakenAt based on the algorithm:
            // 1. Use takenAt if available
            // 2. Use clientCTime if available
            // 3. Otherwise nil
            let guessedTakenAt = takenAt ?? clientCTime
            
            let manifest = OriginalManifest(
                id: normalizedName,
                localID: asset.id,
                sha256: sha256String,
                path: uploadAsset.filename,
                filesize: hashes.plaintextSize,
                name: normalizedName,
                mediaType: asset.mediaType == .video ? "video" : "photo",
                width: metadata.width,
                height: metadata.height,
                modifiedAt: metadata.modifiedAt,
                duration: metadata.duration,
                mimeType: metadata.mimeType,
                location: location,
                isFavorite: metadata.isFavorite,
                isHidden: metadata.isHidden,
                burstIdentifier: metadata.burstIdentifier,
                takenAt: takenAt,
                clientCTime: clientCTime,
                guessedTakenAt: guessedTakenAt
            )
            
            log("Created manifest (normalized from: \(asset.id))", context: "PhotoSync")
            
            let startTime = Date()
            var lastUpdateTime = startTime
            var lastBytesSent: Int64 = 0
            let wrappedDEK = try EncryptionUtils.wrapDEK(dek, withKEK: activeKEK.kek, kekEpoch: activeKEK.epoch).base64EncodedString()
            let uploaded = try await manager.addLFSFileEncrypting(
                at: assetFileURL,
                dek: dek,
                oid: hashes.encryptedOID,
                size: hashes.encryptedSize,
                for: manifest
            ) { bytesSent, totalBytes in
                let now = Date()
                let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
                
                if timeSinceLastUpdate >= 1.0 {
                    let bytesSinceLastUpdate = bytesSent - lastBytesSent
                    let speed = Double(bytesSinceLastUpdate) / timeSinceLastUpdate
                    let speedString = self.formatSpeed(speed)
                    
                    Task { @MainActor in
                        self.updateStateIfCurrent(
                            .syncing(
                                current: loopIndex + 1 - dbSkippedCount,
                                total: assetsRequiringDatabaseChecks.count - dbSkippedCount,
                                currentFile: uploadAsset.filename,
                                uploadSpeed: speedString,
                                fileSize: fileSize
                            ),
                            generation: generation
                        )
                    }
                    
                    lastUpdateTime = now
                    lastBytesSent = bytesSent
                }
            }
            let pointer = EncryptedLFSPointer(
                oid: uploaded.oid,
                size: uploaded.size,
                kekEpoch: activeKEK.epoch,
                wrappedDEK: wrappedDEK
            )
            
            let uploadDuration = Date().timeIntervalSince(startTime)
            let avgSpeed = uploadDuration > 0 ? Double(pointer.size) / uploadDuration : 0
            let speedString = formatSpeed(avgSpeed)
            
            log("LFS upload complete. OID: \(pointer.oid), Size: \(pointer.size), Speed: \(speedString), Duration: \(String(format: "%.2f", uploadDuration))s", context: "PhotoSync")
            await updateState(
                .syncing(
                    current: loopIndex + 1 - dbSkippedCount,
                    total: assetsRequiringDatabaseChecks.count - dbSkippedCount,
                    currentFile: uploadAsset.filename,
                    uploadSpeed: speedString,
                    fileSize: fileSize
                ),
                generation: generation
            )
            
            var items: [GitCommitItem] = [
                .lfs(forManifest: manifest, pointer: pointer),
                .manifest(manifest)
            ]
            
            if asset.mediaType == .image || asset.mediaType == .video {
                log("Generating thumbnails for \(asset.mediaType == .video ? "video" : "image")...", context: "PhotoSync")
                
                let thumbnailSizes: [(name: String, generator: () async throws -> (data: Data, width: Int, height: Int))] = [
                    ("150x150", { try await self.photoLibrary.generateThumbnail(for: uploadAsset, size: CGSize(width: 150, height: 150)) }),
                    ("225x225", { try await self.photoLibrary.generateThumbnail(for: uploadAsset, size: CGSize(width: 225, height: 225)) }),
                    ("1024", { try await self.photoLibrary.generateThumbnailLongestEdge(for: uploadAsset, longestEdge: 1024) })
                ]
                var thumbnailEntries: [ThumbnailSetManifest.Spec.Entry] = []
                var thumbnailLfsItems: [GitCommitItem] = []
                
                for (sizeName, generator) in thumbnailSizes {
                    do {
                        log("Generating \(sizeName) thumbnail...", context: "PhotoSync")
                        let thumbnailResult = try await generator()
                        
                        let thumbnailName = "\(normalizedName)-thumb-\(sizeName)"
                        log("Uploading \(sizeName) thumbnail to LFS...", context: "PhotoSync")
                        let preparedThumbnail = try await encryptThumbnail(
                            data: thumbnailResult.data,
                            kek: activeKEK.kek,
                            kekEpoch: activeKEK.epoch
                        )
                        let thumbnailSha256 = preparedThumbnail.sha256
                        log("Thumbnail \(sizeName) SHA256: \(thumbnailSha256)", context: "PhotoSync")
                        let thumbnailEncrypted = preparedThumbnail.encrypted
                        let thumbnailWrappedDEK = preparedThumbnail.wrappedDEK
                        let uploadedThumbnail = try await manager.addLFSData(
                            thumbnailEncrypted,
                            apiVersion: ThumbnailSetManifest.apiVersion,
                            kind: ThumbnailSetManifest.kind,
                            name: thumbnailName
                        ) { _, _ in }
                        let thumbnailPointer = EncryptedLFSPointer(
                            oid: uploadedThumbnail.oid,
                            size: uploadedThumbnail.size,
                            kekEpoch: activeKEK.epoch,
                            wrappedDEK: thumbnailWrappedDEK
                        )
                        log("Thumbnail \(sizeName) uploaded. OID: \(thumbnailPointer.oid), Size: \(thumbnailPointer.size)", context: "PhotoSync")
                        thumbnailEntries.append(
                            ThumbnailSetManifest.Spec.Entry(
                                name: thumbnailName,
                                sha256: thumbnailSha256,
                                width: thumbnailResult.width,
                                height: thumbnailResult.height,
                                filesize: Int64(thumbnailResult.data.count)
                            )
                        )
                        thumbnailLfsItems.append(
                            .lfsEntry(
                                apiVersion: ThumbnailSetManifest.apiVersion,
                                kind: ThumbnailSetManifest.kind,
                                name: thumbnailName,
                                pointer: thumbnailPointer
                            )
                        )
                    } catch {
                        logWarning("Thumbnail \(sizeName) generation failed for \(uploadAsset.filename), continuing without this thumbnail: \(error.localizedDescription)", context: "PhotoSync")
                    }
                }

                if !thumbnailEntries.isEmpty {
                    let thumbnailSetManifest = ThumbnailSetManifest(
                        originalRef: "\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(normalizedName)",
                        thumbnails: thumbnailEntries,
                        name: "\(normalizedName)-thumbs"
                    )
                    items.append(contentsOf: thumbnailLfsItems)
                    items.append(.manifest(thumbnailSetManifest))
                    log("Created thumbnail set manifest with \(thumbnailEntries.count) entries", context: "PhotoSync")
                }
            }
            
            let dateString = asset.creationDate.map { dateFormatter.string(from: $0) } ?? "unknown date"
            let commitMessage = "Add \(asset.mediaType == .video ? "video" : "photo"): \(uploadAsset.filename)\n\nCaptured: \(dateString)\nSize: \(pointer.size) bytes\nLFS OID: \(pointer.oid)\nSHA256: \(sha256String)"
            
            log("Creating commit with LFS pointer and manifest...", context: "PhotoSync")
            try await manager.createCommit(message: commitMessage, items: items)
            log("Commit created successfully for \(uploadAsset.filename)", context: "PhotoSync")
            uploadedMediaCache.addPending(localID: asset.id, modifiedAt: assetModifiedAt)
            
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        let totalSkippedCount = cacheSkippedCount + dbSkippedCount
        if totalSkippedCount > 0 {
            log("Skipped \(totalSkippedCount) files that were already uploaded", context: "PhotoSync")
        }
        
        return assetsRequiringDatabaseChecks.count - dbSkippedCount
    }
    
    // Enumerates the photo library off the main actor. The fetch walks every
    // asset synchronously, and upload starts it from the main actor.
    func loadAssets() async throws -> [PhotoAsset] {
        nonisolated(unsafe) let library = photoLibrary
        return try await BackgroundWork.run {
            library.fetchAllAssets()
        }
    }

    // Hashes and encrypts one original off the main actor. The pass reads the
    // whole file, so running it on the upload task stalls scrolling.
    func hashAsset(
        fileURL: URL,
        dek: Data
    ) async throws -> (plaintextSHA256: String, encryptedOID: String, encryptedSize: Int64, plaintextSize: Int64) {
        try await BackgroundWork.run {
            try EncryptionUtils.computeStreamingHashes(fileURL: fileURL, dek: dek)
        }
    }

    // Encrypts one thumbnail off the main actor. Upload builds three of these
    // per photo, and that AES work was running on the main actor.
    func encryptThumbnail(
        data: Data,
        kek: Data,
        kekEpoch: Int
    ) async throws -> (sha256: String, encrypted: Data, wrappedDEK: String) {
        try await BackgroundWork.run {
            let digest = SHA256.hash(data: data)
            let sha256 = digest.map { String(format: "%02x", $0) }.joined()
            let thumbnailDEK = EncryptionUtils.randomKey(length: 32)
            let encrypted = try EncryptionUtils.encryptChunkedBinary(
                plaintext: data,
                dek: thumbnailDEK
            )
            let wrappedDEK = try EncryptionUtils.wrapDEK(
                thumbnailDEK,
                withKEK: kek,
                kekEpoch: kekEpoch
            ).base64EncodedString()
            return (sha256, encrypted, wrappedDEK)
        }
    }

    // Applies state transitions only when they belong to the active sync generation.
    private func updateState(_ state: SyncState, generation: UInt64) async {
        guard generation == syncGeneration else { return }
        setSyncState(state)
        if case .completed(let total) = state {
            log("State updated to completed (total: \(total))", context: "PhotoSync")
            // A catch-up, including an empty library, means nothing is waiting,
            // so the reminder moves a full week out instead of firing.
            await backlogTracker.restartIfArmed(now: Date())
        } else if case .failed(let error) = state {
            logError("State updated to failed: \(error.localizedDescription)", context: "PhotoSync")
        }
    }

    // Applies a state update when callbacks still belong to the current run, preventing stale progress resurrection.
    private func updateStateIfCurrent(_ state: SyncState, generation: UInt64) {
        guard generation == syncGeneration else { return }
        setSyncState(state)
    }

    // Keeps button and progress UI consistent by deriving isSyncing directly from SyncState.
    private func setSyncState(_ state: SyncState) {
        syncState = state
        if case .syncing = state {
            isSyncing = true
        } else {
            isSyncing = false
        }
        idleTimer.isIdleTimerDisabled = isSyncing
    }

    // Puts the smallest known originals first. A missing size sorts last so
    // one unreadable length cannot block every smaller file behind it.
    static func orderedSmallestFirst(
        _ assets: [PhotoAsset],
        sizes: [String: Int64]
    ) -> [PhotoAsset] {
        assets.enumerated().sorted { left, right in
            let leftSize = sizes[left.element.id]
            let rightSize = sizes[right.element.id]
            switch (leftSize, rightSize) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left.offset < right.offset
            }
        }.map(\.element)
    }

    // Sorts only the files this run still has to upload. Sizes come from
    // local metadata, off the main actor, so the scan does not hitch the UI.
    private func orderSmallestFirst(
        _ entries: [(asset: PhotoAsset, modifiedAt: String?)]
    ) async -> [(asset: PhotoAsset, modifiedAt: String?)] {
        let sizes = await originalFileSizes(for: entries.map(\.asset))
        let ordered = Self.orderedSmallestFirst(entries.map(\.asset), sizes: sizes)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.asset.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }

    // Looks up sizes off the main actor. The lookup is metadata only, but a
    // large library should not do it on the actor that scrolls the timeline.
    private func originalFileSizes(for assets: [PhotoAsset]) async -> [String: Int64] {
        nonisolated(unsafe) let library = photoLibrary
        let measured = try? await BackgroundWork.run { () -> [String: Int64] in
            var sizes: [String: Int64] = [:]
            for asset in assets {
                if let size = library.originalFileSize(for: asset) {
                    sizes[asset.id] = size
                }
            }
            return sizes
        }
        return measured ?? [:]
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
    
    private func normalizeObjectName(_ name: String) -> String {
        var normalized = name.lowercased()
        
        normalized = normalized.replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        
        normalized = normalized.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        if normalized.isEmpty || !normalized.first!.isLetter {
            normalized = "a" + normalized
        }
        
        if normalized.count > 253 {
            normalized = String(normalized.prefix(253))
        }
        
        return normalized
    }

    // Deletes managed temp upload copies after each asset so image URL normalization does not leak temporary files across long sync runs.
    private func cleanupTemporaryUploadFileIfNeeded(_ fileURL: URL) {
        let tempDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.path.hasPrefix(tempDirectory.path),
              normalizedURL.lastPathComponent.hasPrefix("replycant-upload-") else {
            return
        }
        try? FileManager.default.removeItem(at: normalizedURL)
    }
}

