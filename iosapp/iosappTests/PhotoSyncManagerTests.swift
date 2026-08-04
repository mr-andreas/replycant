import Foundation
import Testing
import Photos
import UIKit
import AVFoundation
import Combine
import CryptoKit
import GitDB
@testable import iosapp
import LibGit2

// Mock photo library provider for testing PhotoSyncManager without Photos framework.
// Simulates asset fetching, data retrieval, thumbnail generation, and authorization.
class MockPhotoLibraryProvider: PhotoLibraryProviding {
    private let _assets: [PhotoAsset]
    var assetData: [String: Data]
    var thumbnails: [String: (data: Data, width: Int, height: Int)]
    var metadata: [String: MediaMetadata]
    var localThumbnails: [String: UIImage]
    var localOriginalImageData: [String: Data]
    var localVideoAssetURLs: [String: URL]
    var localThumbnailRequests: [(localID: String, size: CGSize)] = []
    
    var shouldAuthorize = true
    // Allows tests to model whether callers should attempt local Photo Library lookup.
    var isAuthorized = true
    var authError: Error?
    var dataError: Error?
    var thumbnailError: Error?
    private(set) var getAssetFileURLCalls = 0
    private(set) var filenameCalls = 0
    
    init(
        assets: [PhotoAsset] = [],
        assetData: [String: Data] = [:],
        thumbnails: [String: (data: Data, width: Int, height: Int)] = [:],
        metadata: [String: MediaMetadata] = [:],
        localThumbnails: [String: UIImage] = [:],
        localOriginalImageData: [String: Data] = [:],
        localVideoAssetURLs: [String: URL] = [:]
    ) {
        self._assets = assets
        self.assetData = assetData
        self.thumbnails = thumbnails
        self.metadata = metadata
        self.localThumbnails = localThumbnails
        self.localOriginalImageData = localOriginalImageData
        self.localVideoAssetURLs = localVideoAssetURLs
    }
    
    func requestAuthorization() async -> Bool {
        if authError != nil {
            return false
        }
        return shouldAuthorize
    }
    
    nonisolated func fetchAllAssets() -> [PhotoAsset] {
        return _assets
    }

    // Tracks deferred filename resolution so tests can verify cache-hit runs avoid expensive filename lookups.
    func filename(for photoAsset: PhotoAsset) -> String {
        filenameCalls += 1
        return photoAsset.filename
    }
    
    func getAssetData(for photoAsset: PhotoAsset) async throws -> Data {
        if let error = dataError {
            throw error
        }
        
        guard let data = assetData[photoAsset.id] else {
            throw PhotoLibraryError.assetDataUnavailable
        }
        
        return data
    }

    // Provides file-backed access for streaming upload tests so PhotoSyncManager can exercise URL-based source reads.
    func getAssetFileURL(for photoAsset: PhotoAsset) async throws -> URL {
        getAssetFileURLCalls += 1
        if let error = dataError {
            throw error
        }

        guard let data = assetData[photoAsset.id] else {
            throw PhotoLibraryError.assetDataUnavailable
        }

        let fileExtension = URL(fileURLWithPath: photoAsset.filename).pathExtension.isEmpty
            ? "bin"
            : URL(fileURLWithPath: photoAsset.filename).pathExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-photo-asset-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
    
    func generateThumbnail(for photoAsset: PhotoAsset, size: CGSize) async throws -> (data: Data, width: Int, height: Int) {
        if let error = thumbnailError {
            throw error
        }
        
        let key = "\(photoAsset.id)-\(Int(size.width))x\(Int(size.height))"
        guard let thumbnail = thumbnails[key] else {
            throw PhotoLibraryError.assetDataUnavailable
        }
        
        return thumbnail
    }
    
    func generateThumbnailLongestEdge(for photoAsset: PhotoAsset, longestEdge: CGFloat) async throws -> (data: Data, width: Int, height: Int) {
        if let error = thumbnailError {
            throw error
        }
        
        let key = "\(photoAsset.id)-\(Int(longestEdge))"
        guard let thumbnail = thumbnails[key] else {
            throw PhotoLibraryError.assetDataUnavailable
        }
        
        return thumbnail
    }

    // Serves deterministic local thumbnails in tests to exercise timeline local-first loading behavior.
    func generateThumbnail(forLocalIdentifier localID: String, size: CGSize) async -> UIImage? {
        localThumbnailRequests.append((localID: localID, size: size))
        return localThumbnails[localID]
    }

    // Supplies deterministic local original-image bytes for fullscreen local-first loading tests.
    func getOriginalImageData(forLocalIdentifier localID: String) async -> Data? {
        localOriginalImageData[localID]
    }

    // Supplies deterministic local video file URLs for fullscreen local-first playback tests.
    func getVideoURL(forLocalIdentifier localID: String) async -> URL? {
        localVideoAssetURLs[localID]
    }
    
    nonisolated func extractMetadata(for photoAsset: PhotoAsset) -> MediaMetadata {
        return metadata[photoAsset.id] ?? MediaMetadata(
            width: 1920,
            height: 1080,
            takenAt: "2024-01-01T10:00:00Z",
            modifiedAt: "2024-01-01T10:00:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
    }
}

// Mock manifest manager for testing PhotoSyncManager without git infrastructure.
// Records all operations and allows configurable responses and failures.
@MainActor
class MockManifestManager: ManifestManager {
    var loadedManifests: [String: any Manifest] = [:]
    var addLFSDataCalls: [(data: Data, manifest: any Manifest)] = []
    var addLFSFileEncryptingCalls: [(fileURL: URL, manifest: any Manifest, oid: String, size: Int64)] = []
    var createCommitCalls: [(message: String, items: [GitCommitItem])] = []
    var syncToHeadCalls = 0
    var loadedOriginalBySHA256: [String: OriginalManifest] = [:]
    var uploadedLocalIDs: [String: String?] = [:]
    
    var loadManifestError: Error?
    var addLFSDataError: Error?
    var createCommitError: Error?
    var holdUploadsUntilCancel = false
    var emitLateProgressAfterCancel = false
    var addLFSDataStartHook: (() -> Void)?
    private(set) var cancelActiveUploadCalls = 0
    private var cancelRequested = false
    
    func loadManifest<T: Manifest>(deviceSpace: String?, id: String) async throws -> T? {
        if let error = loadManifestError {
            throw error
        }
        
        let key = "\(T.kind)-\(id)"
        return loadedManifests[key] as? T
    }
    
    func loadAllManifests<T: Manifest>(deviceSpace: String?) async throws -> [T] {
        if let error = loadManifestError {
            throw error
        }
        
        return loadedManifests.values.compactMap { $0 as? T }
    }

    // Returns timeline count from loaded fixture manifests so sparse timeline paths can be exercised in tests.
    func countTimelineOriginals() async throws -> Int {
        timelineOriginals().count
    }

    // Returns offset pages from fixture manifests to satisfy sparse timeline protocol conformance in tests.
    func loadTimelinePage(offset: Int, limit: Int) async throws -> [OriginalManifest] {
        let sorted = timelineOriginals()
        guard limit > 0, offset < sorted.count else { return [] }
        let start = max(0, offset)
        let end = min(sorted.count, start + limit)
        return Array(sorted[start..<end])
    }

    // Returns originals older than a cursor from fixture manifests for sparse backward paging tests.
    func loadTimelinePage(before: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let filtered = timelineOriginals().filter {
            guard let date = $0.spec.guessedTakenAt else { return false }
            return (date, $0.id) < (before.date, before.id)
        }
        return Array(filtered.suffix(limit))
    }

    // Returns originals newer than a cursor from fixture manifests for sparse forward paging tests.
    func loadTimelinePage(after: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let filtered = timelineOriginals().filter {
            guard let date = $0.spec.guessedTakenAt else { return false }
            return (date, $0.id) > (after.date, after.id)
        }
        return Array(filtered.prefix(limit))
    }

    // Aggregates fixture originals by month so tests depending on month-jump APIs keep protocol parity.
    func loadTimelineMonthCounts() async throws -> [TimelineMonthCount] {
        var grouped: [TimelineYearMonth: Int] = [:]
        let calendar = Calendar.current
        for original in timelineOriginals() {
            guard let date = original.spec.guessedTakenAt else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            let key = TimelineYearMonth(year: year, month: month)
            grouped[key, default: 0] += 1
        }
        return grouped.keys
            .sorted {
                if $0.year != $1.year {
                    return $0.year < $1.year
                }
                return $0.month < $1.month
            }
            .map { key in
                TimelineMonthCount(year: key.year, month: key.month, count: grouped[key] ?? 0)
            }
    }

    // Resolves thumbnails by originalRef from fixture manifests so sparse timeline thumbnail lookups work in tests.
    func loadThumbnailsByOriginalRefs(_ refs: [String]) async throws -> [String : ThumbnailSetManifest] {
        guard !refs.isEmpty else { return [:] }
        let thumbs: [ThumbnailSetManifest] = loadedManifests.values.compactMap { $0 as? ThumbnailSetManifest }
        let refSet = Set(refs)
        var result: [String: ThumbnailSetManifest] = [:]
        for thumb in thumbs where refSet.contains(thumb.spec.originalRef) {
            result[thumb.spec.originalRef] = thumb
        }
        return result
    }

    // Produces deterministic timeline ordering from fixture manifests to mirror database-backed sort semantics.
    private func timelineOriginals() -> [OriginalManifest] {
        let manifests: [OriginalManifest] = loadedManifests.values.compactMap { $0 as? OriginalManifest }
        return manifests
            .filter { $0.spec.guessedTakenAt != nil }
            .sorted {
                let leftDate = $0.spec.guessedTakenAt ?? .distantPast
                let rightDate = $1.spec.guessedTakenAt ?? .distantPast
                if leftDate == rightDate {
                    return $0.id < $1.id
                }
                return leftDate < rightDate
            }
    }

    // Provides hash-based lookup behavior used by upload deduplication flow.
    func loadOriginalBySHA256(_ sha256: String) async throws -> OriginalManifest? {
        loadedOriginalBySHA256[sha256]
    }

    // Returns known local IDs so sync can skip unchanged assets before hashing.
    func loadUploadedLocalIDs() async throws -> [String : String?] {
        uploadedLocalIDs
    }

    // Tracks explicit cache-to-head sync requests before upload batches run.
    func syncToHead(progressHandler: SyncProgressHandler?) async throws {
        syncToHeadCalls += 1
    }
    
    func createCommit(message: String, items: [GitCommitItem]) async throws {
        if let error = createCommitError {
            throw error
        }
        
        createCommitCalls.append((message, items))
    }
    
    // Simulates upload behavior with optional in-flight blocking so cancellation races can be tested deterministically.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(_ data: Data, for manifest: any Manifest, progressHandler: ((Int64, Int64) -> Void)?) async throws -> LFSPointer {
        if let error = addLFSDataError {
            throw error
        }
        
        addLFSDataCalls.append((data, manifest))
        let totalBytes = Int64(data.count)
        
        // Simulate progress.
        if let progressHandler = progressHandler {
            progressHandler(totalBytes / 2, totalBytes)
        }

        if holdUploadsUntilCancel {
            addLFSDataStartHook?()
            while !cancelRequested && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if emitLateProgressAfterCancel {
                progressHandler?(totalBytes, totalBytes)
            }
            throw CancellationError()
        }

        if let progressHandler = progressHandler {
            progressHandler(totalBytes, totalBytes)
        }
        
        // Generate realistic LFS pointer.
        let sha256Hash = SHA256.hash(data: data)
        let oid = sha256Hash.compactMap { String(format: "%02x", $0) }.joined()
        let size = Int64(data.count)
        
        return LFSPointer(oid: oid, size: size)
    }

    // Simulates streaming encrypted uploads for originals while preserving deterministic pointer metadata and cancellation semantics.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        for manifest: any Manifest,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        _ = dek
        if let error = addLFSDataError {
            throw error
        }

        addLFSFileEncryptingCalls.append((fileURL, manifest, oid, size))
        let totalBytes = size

        if let progressHandler = progressHandler {
            progressHandler(totalBytes / 2, totalBytes)
        }

        if holdUploadsUntilCancel {
            addLFSDataStartHook?()
            while !cancelRequested && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if emitLateProgressAfterCancel {
                progressHandler?(totalBytes, totalBytes)
            }
            throw CancellationError()
        }

        if let progressHandler = progressHandler {
            progressHandler(totalBytes, totalBytes)
        }

        return LFSPointer(oid: oid, size: size)
    }

    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(
        _ data: Data,
        apiVersion: String,
        kind: String,
        name: String,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        struct EntryManifest: Codable, Manifest {
            static var apiVersion: String { "media.replycant.com/v1alpha1" }
            static var kind: String { "ThumbnailSet" }

            let metadata: Metadata
            let id: String

            struct Metadata: Codable, ManifestMetadata {
                let name: String
                let deviceSpace: String
            }
        }
        return try await addLFSData(
            data,
            for: EntryManifest(metadata: .init(name: name, deviceSpace: "test-device"), id: name),
            progressHandler: progressHandler
        )
    }

    // Records cancellation requests so tests can verify user cancel reaches the upload transport seam.
    func cancelActiveLFSUpload() {
        cancelActiveUploadCalls += 1
        cancelRequested = true
    }
    
}

// Captures idle timer toggles so upload wake-lock behavior can be asserted.
final class MockIdleTimerController: IdleTimerControlling {
    var history: [Bool] = []
    var isIdleTimerDisabled = false {
        didSet { history.append(isIdleTimerDisabled) }
    }
}

// Captures cache reads and pending writes so upload-skip caching behavior can be tested.
@MainActor
final class MockUploadedMediaCache: UploadedMediaCaching {
    var storedEntries: [String: String] = [:]
    var confirmedEntries: [(localID: String, modifiedAt: String?)] = []
    var pendingEntries: [(localID: String, modifiedAt: String?)] = []

    // Simulates fast localID+modifiedAt cache hits before manifest database queries.
    func contains(localID: String, modifiedAt: String?) -> Bool {
        storedEntries[localID] == (modifiedAt ?? "")
    }

    // Records confirmed writes so tests can assert immediate persistence for server-confirmed skip paths.
    func markConfirmed(localID: String, modifiedAt: String?) {
        confirmedEntries.append((localID: localID, modifiedAt: modifiedAt))
        storedEntries[localID] = modifiedAt ?? ""
        pendingEntries.removeAll { $0.localID == localID }
    }

    // Records pending writes so tests can assert push-gated cache population behavior.
    func addPending(localID: String, modifiedAt: String?) {
        pendingEntries.append((localID: localID, modifiedAt: modifiedAt))
    }

    // Simulates push confirmation that promotes pending entries to persisted cache state.
    func flushPending() {
        for pendingEntry in pendingEntries {
            storedEntries[pendingEntry.localID] = pendingEntry.modifiedAt ?? ""
        }
        pendingEntries.removeAll()
    }

    // Resets cache state so reset/resync tests can validate full cache wipe behavior.
    func clear() {
        storedEntries.removeAll()
        confirmedEntries.removeAll()
        pendingEntries.removeAll()
    }
}

// Test suite for PhotoSyncManager
@MainActor
@Suite("PhotoSyncManager Tests", .serialized)
struct PhotoSyncManagerTests {
    
    // MARK: - Test Setup Helpers
    
    func setupTestEnvironment() throws -> String {
        let tempDir = NSTemporaryDirectory()
        let testRepoName = "test-sync-repo-\(UUID().uuidString)"
        let repoPath = (tempDir as NSString).appendingPathComponent(testRepoName)
        
        try? FileManager.default.removeItem(atPath: repoPath)
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        
        try Git.initialize()
        _ = try Repository.create(at: repoPath, bare: false)
        
        return repoPath
    }
    
    func cleanupTestEnvironment(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    func setupDocumentsRepo() throws -> String {
        RepositoryManager.shared.clearRepository()
        GitDBManager.shared.clearGitDB()
        UploadedMediaCache.shared.clear()
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let repoDir = (documentsPath as NSString).appendingPathComponent("replycant-git-db")
        
        try? FileManager.default.removeItem(atPath: repoDir)
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        
        try Git.initialize()
        let repository = try Repository.create(at: repoDir, bare: false)
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "photo-sync-tests")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let bootstrapFiles = try KEKEpochManager(repository: repository).bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        try repository.createCommit(message: "Bootstrap encryption", files: bootstrapFiles)
        
        return repoDir
    }
    
    // Creates PhotoAsset fixtures with optional modification timestamp for dedup prefilter tests.
    func createTestAsset(
        id: String,
        filename: String,
        mediaType: PHAssetMediaType,
        creationDate: Date?,
        modificationDate: Date? = nil
    ) -> PhotoAsset {
        return PhotoAsset(
            id: id,
            phAsset: nil,
            filename: filename,
            creationDate: creationDate,
            modificationDate: modificationDate,
            mediaType: mediaType
        )
    }
    
    // Produces deterministic but unique payloads so SHA-256 dedup tests can distinguish assets by id.
    func createTestData(size: Int = 1024, seed: Int = 0) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            for i in 0..<size {
                ptr[i] = UInt8((i + seed) % 256)
            }
        }
        return data
    }
    
    func createMockLibrary(assets: [PhotoAsset], withThumbnails: Bool = true) -> MockPhotoLibraryProvider {
        var assetData: [String: Data] = [:]
        var thumbnails: [String: (data: Data, width: Int, height: Int)] = [:]
        
        for asset in assets {
            let seed = abs(asset.id.hashValue) % 251
            assetData[asset.id] = createTestData(size: 2048, seed: seed)
            if withThumbnails {
                thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512, seed: seed + 1), 150, 150)
                thumbnails["\(asset.id)-225x225"] = (createTestData(size: 768, seed: seed + 2), 225, 225)
                thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536, seed: seed + 3), 1024, 768)
            }
        }
        
        return MockPhotoLibraryProvider(assets: assets, assetData: assetData, thumbnails: thumbnails)
    }
    
    // MARK: - Happy Path Tests
    
    @Test("Empty library completes with total 0")
    func testEmptyLibrary() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let mockLibrary = MockPhotoLibraryProvider()
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 0)
        } else {
            Issue.record("Expected completed state with total 0")
        }
        
        #expect(mockManifest.createCommitCalls.isEmpty)
    }
    
    @Test("Single image sync")
    func testSingleImageSync() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state with total 1")
        }
        
        // Verify one streaming original upload plus three thumbnail data uploads.
        #expect(mockManifest.addLFSFileEncryptingCalls.count == 1)
        #expect(mockManifest.addLFSDataCalls.count == 3)
        
        // Verify commit was created
        try #require(mockManifest.createCommitCalls.count == 1)
        
        let commitCall = mockManifest.createCommitCalls[0]
        #expect(commitCall.message.contains("photo"))
        #expect(commitCall.items.count == 6) // 1 original (LFS + manifest) + 1 thumbnail set manifest + 3 thumbnail LFS entries
        
        // Verify manifest database sync was requested before upload dedup checks.
        #expect(mockManifest.syncToHeadCalls == 1)
    }
    
    @Test("Single video sync")
    func testSingleVideoSync() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "VID_001", filename: "test.mp4", mediaType: .video, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state with total 1")
        }
        
        // Verify commit message contains "video"
        try #require(mockManifest.createCommitCalls.count == 1)
        let commitCall = mockManifest.createCommitCalls[0]
        #expect(commitCall.message.contains("video"))
    }
    
    @Test("Multiple mixed assets")
    func testMultipleMixedAssets() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset1 = createTestAsset(id: "IMG_001", filename: "photo1.jpg", mediaType: .image, creationDate: Date())
        let asset2 = createTestAsset(id: "VID_001", filename: "video1.mp4", mediaType: .video, creationDate: Date())
        let asset3 = createTestAsset(id: "IMG_002", filename: "photo2.jpg", mediaType: .image, creationDate: Date())
        
        let mockLibrary = createMockLibrary(assets: [asset1, asset2, asset3])
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 3)
        } else {
            Issue.record("Expected completed state with total 3")
        }
        
        // Verify 3 commits were created
        #expect(mockManifest.createCommitCalls.count == 3)
    }

    // Verifies sync preserves the production media ordering contract so
    // newly captured photos and videos reach the server first.
    @Test("Mixed assets upload newest first")
    func testMixedAssetsUploadNewestFirst() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let oldest = createTestAsset(
            id: "IMG_OLD",
            filename: "oldest.jpg",
            mediaType: .image,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let middle = createTestAsset(
            id: "VID_MID",
            filename: "middle.mp4",
            mediaType: .video,
            creationDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let newest = createTestAsset(
            id: "IMG_NEW",
            filename: "newest.jpg",
            mediaType: .image,
            creationDate: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let orderedAssets = PhotoLibraryManager.sortAssetsForUpload([oldest, middle, newest])
        let mockLibrary = createMockLibrary(assets: orderedAssets)
        let mockManifest = MockManifestManager()

        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        await syncManager.startSync()
        await syncManager.syncTask?.value

        #expect(mockManifest.createCommitCalls.count == 3)
        let commitMessages = mockManifest.createCommitCalls.map(\.message)
        #expect(commitMessages[0].contains("newest.jpg"))
        #expect(commitMessages[1].contains("middle.mp4"))
        #expect(commitMessages[2].contains("oldest.jpg"))
    }
    
    // MARK: - Deduplication/Skip Tests
    
    @Test("Pre-populated original is skipped")
    func testSkipExistingOriginal() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset1 = createTestAsset(id: "IMG_001", filename: "photo1.jpg", mediaType: .image, creationDate: Date())
        let asset2 = createTestAsset(id: "IMG_002", filename: "photo2.jpg", mediaType: .image, creationDate: Date())
        
        let mockLibrary = createMockLibrary(assets: [asset1, asset2])
        let mockManifest = MockManifestManager()
        
        // Pre-populate manifest for asset1 by SHA256 so dedup path skips it.
        let existingManifest = OriginalManifest(
            id: "img-001",
            localID: "local_ID/img-001",
            sha256: "abc123",
            path: "photo1.jpg",
            filesize: 2048,
            name: "img-001",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: "2024-01-01T10:00:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )
        let existingData = try #require(mockLibrary.assetData[asset1.id])
        let existingHash = SHA256.hash(data: existingData).compactMap { String(format: "%02x", $0) }.joined()
        mockManifest.loadedOriginalBySHA256[existingHash] = existingManifest
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1) // Only asset2 should be synced
        } else {
            Issue.record("Expected completed state with total 1")
        }
        
        // Verify only 1 commit was created (for asset2)
        #expect(mockManifest.createCommitCalls.count == 1)
    }

    @Test("Unchanged localID skips before file resolution")
    func testSkipExistingLocalIDBeforeHashing() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let modifiedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let asset1 = createTestAsset(
            id: "IMG_010",
            filename: "photo10.jpg",
            mediaType: .image,
            creationDate: modifiedAt,
            modificationDate: modifiedAt
        )
        let asset2 = createTestAsset(
            id: "IMG_011",
            filename: "photo11.jpg",
            mediaType: .image,
            creationDate: Date(timeIntervalSince1970: 1_710_000_100),
            modificationDate: Date(timeIntervalSince1970: 1_710_000_100)
        )

        let mockLibrary = createMockLibrary(assets: [asset1, asset2])
        let mockManifest = MockManifestManager()
        let dateFormatter = ISO8601DateFormatter()
        mockManifest.uploadedLocalIDs[asset1.id] = dateFormatter.string(from: modifiedAt)

        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        await syncManager.startSync()
        await syncManager.syncTask?.value

        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state with total 1")
        }

        #expect(mockLibrary.getAssetFileURLCalls == 1)
        #expect(mockManifest.createCommitCalls.count == 1)
    }

    // Ensures the fast uploaded-media cache can bypass expensive manifest sync when all assets are known unchanged.
    @Test("Fast cache skips without syncing manifest database")
    func testFastCacheSkipsWithoutManifestSync() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let modifiedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let asset = createTestAsset(
            id: "IMG_CACHE_001",
            filename: "cached.jpg",
            mediaType: .image,
            creationDate: modifiedAt,
            modificationDate: modifiedAt
        )

        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        let mockCache = MockUploadedMediaCache()
        let dateFormatter = ISO8601DateFormatter()
        mockCache.storedEntries[asset.id] = dateFormatter.string(from: modifiedAt)

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            uploadedMediaCache: mockCache
        )
        await syncManager.startSync()
        await syncManager.syncTask?.value

        if case .completed(let total) = syncManager.syncState {
            #expect(total == 0)
        } else {
            Issue.record("Expected completed state with total 0")
        }

        #expect(mockManifest.syncToHeadCalls == 0)
        #expect(mockLibrary.getAssetFileURLCalls == 0)
        #expect(mockLibrary.filenameCalls == 0)
        #expect(mockManifest.createCommitCalls.isEmpty)
    }

    // Ensures localID skip path persists immediately so reruns can bypass database and hashing.
    @Test("Slow-path localID skip marks confirmed cache entry")
    func testSlowPathSkipAddsPendingCacheEntry() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let modifiedAt = Date(timeIntervalSince1970: 1_716_000_000)
        let asset = createTestAsset(
            id: "IMG_CACHE_002",
            filename: "slow-path.jpg",
            mediaType: .image,
            creationDate: modifiedAt,
            modificationDate: modifiedAt
        )

        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        let mockCache = MockUploadedMediaCache()
        let dateFormatter = ISO8601DateFormatter()
        mockManifest.uploadedLocalIDs[asset.id] = dateFormatter.string(from: modifiedAt)

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            uploadedMediaCache: mockCache
        )
        await syncManager.startSync()
        await syncManager.syncTask?.value

        #expect(mockManifest.syncToHeadCalls == 1)
        #expect(mockLibrary.getAssetFileURLCalls == 0)
        #expect(mockManifest.createCommitCalls.isEmpty)
        #expect(mockCache.confirmedEntries.count == 1)
        #expect(mockCache.confirmedEntries.first?.localID == asset.id)
        #expect(mockCache.confirmedEntries.first?.modifiedAt == dateFormatter.string(from: modifiedAt))
        #expect(mockCache.pendingEntries.isEmpty)
    }

    // Ensures SHA256 dedup skips also persist immediately so future runs can skip before hashing.
    @Test("SHA256 skip marks confirmed cache entry")
    func testSHA256SkipAddsPendingCacheEntry() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let modifiedAt = Date(timeIntervalSince1970: 1_718_000_000)
        let asset = createTestAsset(
            id: "IMG_CACHE_SHA",
            filename: "sha-skip.jpg",
            mediaType: .image,
            creationDate: modifiedAt,
            modificationDate: modifiedAt
        )

        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        let mockCache = MockUploadedMediaCache()

        let existingManifest = OriginalManifest(
            id: "img-cache-sha",
            localID: "other-device-id",
            sha256: "existing-sha",
            path: "sha-skip.jpg",
            filesize: 2048,
            name: "img-cache-sha",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )
        let existingData = try #require(mockLibrary.assetData[asset.id])
        let existingHash = SHA256.hash(data: existingData).compactMap { String(format: "%02x", $0) }.joined()
        mockManifest.loadedOriginalBySHA256[existingHash] = existingManifest

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            uploadedMediaCache: mockCache
        )
        await syncManager.startSync()
        await syncManager.syncTask?.value

        let dateFormatter = ISO8601DateFormatter()
        #expect(mockManifest.syncToHeadCalls == 1)
        #expect(mockManifest.createCommitCalls.isEmpty)
        #expect(mockCache.confirmedEntries.count == 1)
        #expect(mockCache.confirmedEntries.first?.localID == asset.id)
        #expect(mockCache.confirmedEntries.first?.modifiedAt == dateFormatter.string(from: modifiedAt))
        #expect(mockCache.pendingEntries.isEmpty)
    }

    // Proves end-to-end that one SHA256-skip run persists cache and the next run skips before hashing without flush.
    @Test("Second sync run skips before hashing after SHA256 skip persists cache")
    func testSecondSyncRunSkipsBeforeHashingAfterSHA256SkipPersist() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let modifiedAt = Date(timeIntervalSince1970: 1_719_000_000)
        let asset = createTestAsset(
            id: "IMG_CACHE_INTEGRATION",
            filename: "integration-skip.jpg",
            mediaType: .image,
            creationDate: modifiedAt,
            modificationDate: modifiedAt
        )
        let dateFormatter = ISO8601DateFormatter()
        let modifiedAtString = dateFormatter.string(from: modifiedAt)

        let cacheFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-cache-integration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }
        let firstRunCache = UploadedMediaCache(fileURL: cacheFileURL)
        firstRunCache.clear()

        let firstRunLibrary = createMockLibrary(assets: [asset])
        let firstRunManifest = MockManifestManager()
        let existingManifest = OriginalManifest(
            id: "img-cache-integration",
            localID: "other-device-id",
            sha256: "existing-sha",
            path: "integration-skip.jpg",
            filesize: 2048,
            name: "img-cache-integration",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )
        let existingData = try #require(firstRunLibrary.assetData[asset.id])
        let existingHash = SHA256.hash(data: existingData).compactMap { String(format: "%02x", $0) }.joined()
        firstRunManifest.loadedOriginalBySHA256[existingHash] = existingManifest

        let firstRunSyncManager = PhotoSyncManager(
            photoLibraryProvider: firstRunLibrary,
            manifestManager: firstRunManifest,
            uploadedMediaCache: firstRunCache
        )
        await firstRunSyncManager.startSync()
        await firstRunSyncManager.syncTask?.value

        #expect(firstRunManifest.syncToHeadCalls == 1)
        #expect(firstRunLibrary.getAssetFileURLCalls == 1)
        #expect(firstRunCache.contains(localID: asset.id, modifiedAt: modifiedAtString))

        let secondRunCache = UploadedMediaCache(fileURL: cacheFileURL)
        let secondRunLibrary = createMockLibrary(assets: [asset])
        let secondRunManifest = MockManifestManager()
        let secondRunSyncManager = PhotoSyncManager(
            photoLibraryProvider: secondRunLibrary,
            manifestManager: secondRunManifest,
            uploadedMediaCache: secondRunCache
        )

        await secondRunSyncManager.startSync()
        await secondRunSyncManager.syncTask?.value

        #expect(secondRunManifest.syncToHeadCalls == 0)
        #expect(secondRunLibrary.getAssetFileURLCalls == 0)
        if case .completed(let total) = secondRunSyncManager.syncState {
            #expect(total == 0)
        } else {
            Issue.record("Expected completed state with total 0")
        }
    }

    // Ensures cache-prefiltered runs never emit negative progress counters while still reporting one upload.
    @Test("Progress stays non-negative with cache-prefiltered assets")
    func testProgressStaysNonNegativeWithCachePrefilteredAssets() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let formatter = ISO8601DateFormatter()
        let firstDate = Date(timeIntervalSince1970: 1_717_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_717_000_100)
        let thirdDate = Date(timeIntervalSince1970: 1_717_000_200)
        let firstAsset = createTestAsset(
            id: "IMG_CACHE_A",
            filename: "cache-a.jpg",
            mediaType: .image,
            creationDate: firstDate,
            modificationDate: firstDate
        )
        let secondAsset = createTestAsset(
            id: "IMG_CACHE_B",
            filename: "cache-b.jpg",
            mediaType: .image,
            creationDate: secondDate,
            modificationDate: secondDate
        )
        let uploadAsset = createTestAsset(
            id: "IMG_UPLOAD_C",
            filename: "upload-c.jpg",
            mediaType: .image,
            creationDate: thirdDate,
            modificationDate: thirdDate
        )

        let mockLibrary = createMockLibrary(assets: [firstAsset, secondAsset, uploadAsset])
        let mockManifest = MockManifestManager()
        let mockCache = MockUploadedMediaCache()
        mockCache.storedEntries[secondAsset.id] = formatter.string(from: secondDate)
        mockCache.storedEntries[uploadAsset.id] = formatter.string(from: thirdDate)

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            uploadedMediaCache: mockCache
        )

        var observedStates: [SyncState] = []
        let stateCancellable = syncManager.$syncState.sink { observedStates.append($0) }
        _ = stateCancellable

        await syncManager.startSync()
        await syncManager.syncTask?.value

        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state with total 1")
        }

        let syncingStates = observedStates.compactMap { state -> (current: Int, total: Int)? in
            if case .syncing(let current, let total, _, _, _) = state {
                return (current: current, total: total)
            }
            return nil
        }
        #expect(syncingStates.isEmpty == false)
        for progress in syncingStates {
            #expect(progress.current >= 0)
            #expect(progress.total >= 0)
            if progress.total > 0 {
                #expect(progress.current <= progress.total)
            }
        }
    }

    @Test("Changed localID modification date falls back to hashing")
    func testChangedLocalIDModificationDateDoesNotSkip() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let assetDate = Date(timeIntervalSince1970: 1_710_000_000)
        let asset = createTestAsset(
            id: "IMG_020",
            filename: "photo20.jpg",
            mediaType: .image,
            creationDate: assetDate,
            modificationDate: assetDate
        )

        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        let dateFormatter = ISO8601DateFormatter()
        mockManifest.uploadedLocalIDs[asset.id] = dateFormatter.string(from: Date(timeIntervalSince1970: 1_710_010_000))

        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        await syncManager.startSync()
        await syncManager.syncTask?.value

        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state with total 1")
        }

        #expect(mockLibrary.getAssetFileURLCalls == 1)
        #expect(mockManifest.createCommitCalls.count == 1)
    }
    
    // MARK: - Cancellation Tests
    
    // Waits for a condition to become true by polling with Task.yield()
    // This avoids timing-based tests that can be flaky
    func waitForCondition(maxIterations: Int = 100, condition: () -> Bool) async {
        for _ in 0..<maxIterations {
            if condition() {
                return
            }
            await Task.yield()
        }
    }
    
    @Test("Cancellation mid-sync")
    func testCancellation() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        // Create many assets
        var assets: [PhotoAsset] = []
        for i in 1...10 {
            let asset = createTestAsset(id: "IMG_\(String(format: "%03d", i))", filename: "photo\(i).jpg", mediaType: .image, creationDate: Date())
            assets.append(asset)
        }
        
        let mockLibrary = createMockLibrary(assets: assets)
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        
        // Wait for sync to actually start processing
        await waitForCondition { syncManager.isSyncing == true }
        
        // Now cancel while sync is in progress
        syncManager.cancelSync()
        
        // Wait for cancellation to complete
        await waitForCondition { syncManager.isSyncing == false }
        
        #expect(syncManager.isSyncing == false)
        #expect(syncManager.syncState == .idle)
        
        // Verify not all assets were committed
        #expect(mockManifest.createCommitCalls.count < 10)
    }

    @Test("Cancellation during in-flight upload stays idle and forwards cancel")
    func testCancellationDuringInFlightUploadStaysIdle() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let asset = createTestAsset(id: "IMG_001", filename: "photo1.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        let mockManifest = MockManifestManager()
        mockManifest.holdUploadsUntilCancel = true
        mockManifest.emitLateProgressAfterCancel = true

        var uploadStarted = false
        mockManifest.addLFSDataStartHook = { uploadStarted = true }

        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)

        await syncManager.startSync()
        await waitForCondition(maxIterations: 300) { uploadStarted }
        try #require(uploadStarted)

        syncManager.cancelSync()
        await waitForCondition(maxIterations: 300) { !syncManager.isSyncing }

        #expect(syncManager.isSyncing == false)
        #expect(syncManager.syncState == .idle)
        #expect(mockManifest.cancelActiveUploadCalls == 1)
        #expect(mockManifest.createCommitCalls.isEmpty)
    }

    // Ensures upload start acquires a wake lock so auto-lock cannot interrupt transfer.
    @Test("Idle timer is disabled while upload is actively syncing")
    func testIdleTimerDisabledDuringInFlightUpload() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let asset = createTestAsset(id: "IMG_001", filename: "photo1.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        let mockManifest = MockManifestManager()
        mockManifest.holdUploadsUntilCancel = true
        let idleTimer = MockIdleTimerController()
        var uploadStarted = false
        mockManifest.addLFSDataStartHook = { uploadStarted = true }

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            idleTimer: idleTimer
        )

        await syncManager.startSync()
        await waitForCondition(maxIterations: 300) { uploadStarted }
        await waitForCondition(maxIterations: 300) { idleTimer.isIdleTimerDisabled }

        #expect(syncManager.isSyncing == true)
        #expect(idleTimer.isIdleTimerDisabled == true)

        syncManager.cancelSync()
        await waitForCondition(maxIterations: 300) { !syncManager.isSyncing }
    }

    // Ensures wake lock is always released after a successful upload completion.
    @Test("Idle timer is re-enabled after successful sync")
    func testIdleTimerReenabledAfterSuccessfulSync() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset])
        let mockManifest = MockManifestManager()
        let idleTimer = MockIdleTimerController()

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            idleTimer: idleTimer
        )

        await syncManager.startSync()
        await syncManager.syncTask?.value

        #expect(syncManager.isSyncing == false)
        #expect(idleTimer.isIdleTimerDisabled == false)
        #expect(idleTimer.history.contains(true))
    }

    // Ensures user cancellation releases wake lock to restore normal lock behavior.
    @Test("Idle timer is re-enabled after cancellation")
    func testIdleTimerReenabledAfterCancellation() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let asset = createTestAsset(id: "IMG_001", filename: "photo1.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        let mockManifest = MockManifestManager()
        mockManifest.holdUploadsUntilCancel = true
        let idleTimer = MockIdleTimerController()
        var uploadStarted = false
        mockManifest.addLFSDataStartHook = { uploadStarted = true }

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            idleTimer: idleTimer
        )

        await syncManager.startSync()
        await waitForCondition(maxIterations: 300) { uploadStarted }
        await waitForCondition(maxIterations: 300) { idleTimer.isIdleTimerDisabled }

        syncManager.cancelSync()
        await waitForCondition(maxIterations: 300) { !syncManager.isSyncing }

        #expect(syncManager.syncState == .idle)
        #expect(idleTimer.isIdleTimerDisabled == false)
        #expect(idleTimer.history.contains(true))
    }

    // Ensures failure paths also release wake lock to avoid sticky keep-awake state.
    @Test("Idle timer is re-enabled after sync failure")
    func testIdleTimerReenabledAfterFailure() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }

        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")

        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        let mockManifest = MockManifestManager()
        mockManifest.addLFSDataError = NSError(
            domain: "LFSError",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Upload failed"]
        )
        let idleTimer = MockIdleTimerController()

        let syncManager = PhotoSyncManager(
            photoLibraryProvider: mockLibrary,
            manifestManager: mockManifest,
            idleTimer: idleTimer
        )

        await syncManager.startSync()
        await syncManager.syncTask?.value

        if case .failed = syncManager.syncState {
            #expect(idleTimer.isIdleTimerDisabled == false)
            #expect(idleTimer.history.contains(true))
        } else {
            Issue.record("Expected failed state due to LFS upload error")
        }
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Auth denied error")
    func testAuthDenied() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        mockLibrary.shouldAuthorize = false
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .failed(let error) = syncManager.syncState {
            #expect(error is PhotoLibraryError)
            if let libraryError = error as? PhotoLibraryError {
                #expect(libraryError == .accessDenied)
            }
        } else {
            Issue.record("Expected failed state with accessDenied error")
        }
    }
    
    @Test("Asset data unavailable error")
    func testAssetDataUnavailable() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        // Don't add asset data - will cause error
        let mockLibrary = MockPhotoLibraryProvider(assets: [asset], assetData: [:], thumbnails: [:])
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .failed(let error) = syncManager.syncState {
            #expect(error is PhotoLibraryError)
        } else {
            Issue.record("Expected failed state with assetDataUnavailable error")
        }
    }
    
    @Test("LFS upload failure")
    func testLFSUploadFailure() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        
        let mockManifest = MockManifestManager()
        mockManifest.addLFSDataError = NSError(domain: "LFSError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .failed = syncManager.syncState {
            // Success - sync failed as expected
        } else {
            Issue.record("Expected failed state due to LFS upload error")
        }
    }
    
    @Test("Commit failure")
    func testCommitFailure() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        mockLibrary.thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512), 150, 150)
        mockLibrary.thumbnails["\(asset.id)-225x225"] = (createTestData(size: 768), 225, 225)
        mockLibrary.thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536), 1024, 768)
        
        let mockManifest = MockManifestManager()
        mockManifest.createCommitError = NSError(domain: "GitError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Commit failed"])
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .failed = syncManager.syncState {
            // Success - sync failed as expected
        } else {
            Issue.record("Expected failed state due to commit error")
        }
    }
    
    @Test("Thumbnail generation failure continues for others")
    func testThumbnailFailureContinues() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        
        // Only provide 2 of 3 thumbnails - one will fail
        mockLibrary.thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512), 150, 150)
        mockLibrary.thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536), 1024, 768)
        // Missing: 225x225
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        // Sync should still complete successfully
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state despite thumbnail failure")
        }
        
        // Verify commit was created with original + 2 thumbnails
        try #require(mockManifest.createCommitCalls.count == 1)
        let commitCall = mockManifest.createCommitCalls[0]
        #expect(commitCall.items.count == 5) // 1 original (LFS + manifest) + 1 thumbnail set manifest + 2 thumbnail LFS entries
    }
    
    // MARK: - State Management Tests
    
    @Test("State transitions and isSyncing flag")
    func testStateTransitions() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        mockLibrary.thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512), 150, 150)
        mockLibrary.thumbnails["\(asset.id)-225x225"] = (createTestData(size: 768), 225, 225)
        mockLibrary.thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536), 1024, 768)
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        // Initial state
        #expect(syncManager.isSyncing == false)
        #expect(syncManager.syncState == .idle)
        
        await syncManager.startSync()
        
        // Should be syncing now
        #expect(syncManager.isSyncing == true)
        
        await syncManager.syncTask?.value
        
        // Should be idle again
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state")
        }
    }
    
    // MARK: - Edge Case Tests
    
    @Test("Asset without creationDate")
    func testAssetWithoutCreationDate() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: nil)
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        mockLibrary.thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512), 150, 150)
        mockLibrary.thumbnails["\(asset.id)-225x225"] = (createTestData(size: 768), 225, 225)
        mockLibrary.thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536), 1024, 768)
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state")
        }
        
        // Verify commit was created
        try #require(mockManifest.createCommitCalls.count == 1)
        
        let commitCall = mockManifest.createCommitCalls[0]
        #expect(commitCall.message.contains("unknown date"))
    }
    
    @Test("Metadata variations")
    func testMetadataVariations() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        let asset = createTestAsset(id: "IMG_001", filename: "test.jpg", mediaType: .image, creationDate: Date())
        let mockLibrary = createMockLibrary(assets: [asset], withThumbnails: false)
        mockLibrary.thumbnails["\(asset.id)-150x150"] = (createTestData(size: 512), 150, 150)
        mockLibrary.thumbnails["\(asset.id)-225x225"] = (createTestData(size: 768), 225, 225)
        mockLibrary.thumbnails["\(asset.id)-1024"] = (createTestData(size: 1536), 1024, 768)
        
        // Set metadata with location, favorite, hidden, burstIdentifier
        mockLibrary.metadata[asset.id] = MediaMetadata(
            width: 1920,
            height: 1080,
            takenAt: "2024-01-01T10:00:00Z",
            modifiedAt: "2024-01-01T10:00:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: MediaMetadata.Location(latitude: 37.7749, longitude: -122.4194, altitude: 10.0),
            isFavorite: true,
            isHidden: true,
            burstIdentifier: "BURST123"
        )
        
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == 1)
        } else {
            Issue.record("Expected completed state")
        }
        
        // Verify commit was created
        try #require(mockManifest.createCommitCalls.count == 1)
        
        // Verify manifest has metadata
        let commitCall = mockManifest.createCommitCalls[0]
        var hasOriginalManifest = false
        for item in commitCall.items {
            if case .manifest(let manifest) = item {
                if let original = manifest as? OriginalManifest {
                    hasOriginalManifest = true
                    #expect(original.spec.location != nil)
                    #expect(original.spec.isFavorite == true)
                    #expect(original.spec.isHidden == true)
                    #expect(original.spec.burstIdentifier == "BURST123")
                }
            }
        }
        #expect(hasOriginalManifest)
    }
    
    @Test("Name normalization produces valid names")
    func testNameNormalization() async throws {
        let repoPath = try setupDocumentsRepo()
        defer { cleanupTestEnvironment(at: repoPath) }
        
        UserDefaults.standard.set("http://localhost:8080/lfs", forKey: "gitServerURL")
        
        // Test various problematic names
        let testCases = [
            ("IMG_001/ABC", "img-001-abc"),
            ("123_START", "a123-start"),
            ("VERY_LONG_NAME_" + String(repeating: "X", count: 300), nil), // Will be truncated to 253
            ("Special!@#$%Chars", "special-chars")
        ]
        
        var assets: [PhotoAsset] = []
        for (originalId, _) in testCases {
            let asset = createTestAsset(id: originalId, filename: "test.jpg", mediaType: .image, creationDate: Date())
            assets.append(asset)
        }
        
        let mockLibrary = createMockLibrary(assets: assets)
        let mockManifest = MockManifestManager()
        
        let syncManager = PhotoSyncManager(photoLibraryProvider: mockLibrary, manifestManager: mockManifest)
        
        await syncManager.startSync()
        await syncManager.syncTask?.value
        
        #expect(syncManager.isSyncing == false)
        
        if case .completed(let total) = syncManager.syncState {
            #expect(total == testCases.count)
        } else {
            Issue.record("Expected completed state")
        }
        
        // Verify all manifests have valid normalized names
        for commitCall in mockManifest.createCommitCalls {
            for item in commitCall.items {
                if case .manifest(let manifest) = item {
                    if let original = manifest as? OriginalManifest {
                        let name = original.metadata.name
                        
                        // Check name starts with letter
                        #expect(name.first?.isLetter == true)
                        
                        // Check name is not too long
                        #expect(name.count <= 253)
                        
                        // Check name only contains valid characters
                        let validCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
                        #expect(name.unicodeScalars.allSatisfy { validCharacterSet.contains($0) })
                    }
                }
            }
        }
    }
}

