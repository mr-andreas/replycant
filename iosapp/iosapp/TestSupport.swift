import Foundation
import LibGit2
import CryptoKit
import UIKit
import GitDB

#if DEBUG
// Test support code for UI testing
// This exists to keep UITest-only fixture setup out of shipped builds.
class TestSupport {
    // Keeps screenshot fixture media bytes and dimensions together so metadata and thumbnails stay consistent.
    struct ScreenshotFixturePhoto {
        let name: String
        let data: Data
        let width: Int
        let height: Int
    }

    // Enumerates generated fixture entries so screenshot timelines can map each row to a source demo photo.
    struct ScreenshotFixtureEntry {
        let name: String
        let timestamp: String
        let sourceIndex: Int
    }

    // Captures per-item fixture inputs so test repositories can mix screenshot photos and synthetic/video fixtures.
    private struct FixtureSeed {
        let name: String
        let timestamp: String
        let mediaType: String
        let sourcePhoto: ScreenshotFixturePhoto?
    }

    // Defines image resize behavior for each thumbnail variant so screenshot fixtures mimic production thumbnail shapes.
    private enum ThumbnailRecipe {
        case square(Int)
        case maxDimension(Int)
    }

    // Reports setup failures with actionable messages when screenshot fixture media is missing or invalid.
    enum SetupError: LocalizedError {
        case missingScreenshotMediaDirectory
        case missingScreenshotMediaFiles
        case failedToLoadScreenshotMedia(path: String)

        var errorDescription: String? {
            switch self {
            case .missingScreenshotMediaDirectory:
                return "ScreenshotMedia directory is missing from the app bundle"
            case .missingScreenshotMediaFiles:
                return "No screenshot fixture images found in ScreenshotMedia"
            case .failedToLoadScreenshotMedia(let path):
                return "Failed to decode screenshot fixture image at \(path)"
            }
        }
    }

    // Shards fixture filenames so UITest repositories mirror production git tree layout.
    private static func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }
    
    // Centralizes launch-argument-gated UITest setup before app services start.
    static func setupTestEnvironment() {
        print("TestSupport: Setting up test environment")
        
        // Check if we're in test mode
        guard ProcessInfo.processInfo.arguments.contains("--uitesting") else {
            print("TestSupport: Not in test mode, skipping setup")
            return
        }

        // Wipes prior UITest library state so privacy screenshots can show a clean onboarding flow.
        if ProcessInfo.processInfo.arguments.contains("--screenshots-onboarding") {
            resetLocalStateForScreenshotOnboarding()
        }
        
        print("TestSupport: Running in UI test mode")
        
        // Start test LFS server
        do {
            try TestLFSServer.shared.start()
        } catch {
            fatalError("TestSupport: Failed to start test LFS server: \(error)")
        }
        
        // Set up test repository
        do {
            try setupTestRepository()
            setupTestUserDefaults()
            print("TestSupport: Test environment setup complete")
        } catch {
            // Surfaces the concrete setup failure in simulator logs before the intentional trap.
            print("TestSupport: Failed to setup test environment: \(error)")
            fatalError("TestSupport: Failed to setup test environment: \(error)")
        }

        // Rotate phone to portrait mode
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        
    }
    
    // Builds a UI-test repository that mirrors production encrypted LFS pointer behavior for timeline loading.
    private static func setupTestRepository() throws {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let repoDir = (documentsPath as NSString).appendingPathComponent("replycant-git-db")
        print("TestSupport: Setting up test repository at: \(repoDir)")
        
        // Clean up any existing repository
        if FileManager.default.fileExists(atPath: repoDir) {
            print("TestSupport: Removing existing repository")
            try FileManager.default.removeItem(atPath: repoDir)
        }
        
        // Create new repository
        try Git.initialize()
        let repo = try Repository.create(at: repoDir, bare: false)

        // Ensure age identity exists before creating epoch files used by pointer decryption.
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "test-device-uitest")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let kekEpochManager = KEKEpochManager(repository: repo)
        let kekEpoch = 1
        let bootstrapFiles = try kekEpochManager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        let activeKEK = try kekEpochManager.loadKEK(epoch: kekEpoch)
        
        // Create test device space
        let deviceSpace = "test-device-uitest"
        
        // Create directory structure
        let manifestDir = (repoDir as NSString).appendingPathComponent("manifests/\(deviceSpace)/media.replycant.com/v1alpha1")
        let originalManifestDir = (manifestDir as NSString).appendingPathComponent("Original")
        let thumbnailManifestDir = (manifestDir as NSString).appendingPathComponent("ThumbnailSet")
        let binaryDir = (repoDir as NSString).appendingPathComponent("binary/\(deviceSpace)/media.replycant.com/v1alpha1")
        let originalBinaryDir = (binaryDir as NSString).appendingPathComponent("Original")
        let thumbnailBinaryDir = (binaryDir as NSString).appendingPathComponent("ThumbnailSet")
        
        try FileManager.default.createDirectory(atPath: originalManifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: thumbnailManifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: originalBinaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: thumbnailBinaryDir, withIntermediateDirectories: true)
        
        let useScreenshotFixtures = shouldUseScreenshotFixtures(arguments: ProcessInfo.processInfo.arguments)
        let screenshotPhotos = try loadScreenshotMediaFromBundleIfNeeded(useScreenshotFixtures: useScreenshotFixtures)
        let fixtureSeeds = buildFixtureSeeds(useScreenshotFixtures: useScreenshotFixtures, screenshotPhotos: screenshotPhotos)
        
        var filesToCommit: [(path: String, content: String)] = bootstrapFiles
        
        for fixtureSeed in fixtureSeeds {
            let name = fixtureSeed.name
            let timestamp = fixtureSeed.timestamp
            let mediaType = fixtureSeed.mediaType
            let originalData: Data
            let originalHash: String
            let videoDuration: Double
            let videoWidth: Int
            let videoHeight: Int
            
            if mediaType == "video" && name == "v-1" {
                guard let videoData = loadVideoFromBundle(filename: "Big_Buck_Bunny_360_10s_1MB.mp4") else {
                    fatalError("Test video file Big_Buck_Bunny_360_10s_1MB.mp4 not found")
                }
                
                originalData = videoData
                originalHash = calculateSHA256(data: videoData)
                videoDuration = getVideoDuration(from: videoData)
                videoWidth = 640
                videoHeight = 360
                
                TestLFSServer.shared.store(oid: originalHash, data: videoData)
                let playlist = generateHLSPlaylist(oid: originalHash, duration: videoDuration, resolution: "\(videoWidth)x\(videoHeight)")
                TestLFSServer.shared.registerHLSPlaylist(oid: originalHash, playlistContent: playlist)
            } else if let sourcePhoto = fixtureSeed.sourcePhoto {
                originalData = sourcePhoto.data
                originalHash = calculateSHA256(data: originalData)
                videoDuration = 0
                videoWidth = sourcePhoto.width
                videoHeight = sourcePhoto.height
            } else if name.hasPrefix("o-") {
                originalData = createTestImageJPEG(width: 10, height: 10, name: name)
                originalHash = calculateSHA256(data: originalData)
                videoDuration = 0
                videoWidth = 10
                videoHeight = 10
            } else {
                originalData = createTestImageJPEG(width: 1920, height: 1080, name: name)
                originalHash = calculateSHA256(data: originalData)
                videoDuration = 0
                videoWidth = 1920
                videoHeight = 1080
            }
            
            // Create original manifest
            let fileExtension = mediaType == "video" ? "mp4" : "jpg"
            let mimeType = mediaType == "video" ? "video/mp4" : "image/jpeg"
            let width = videoWidth
            let height = videoHeight
            
            // Build manifest with optional duration field for videos
            var manifestLines = [
                "apiVersion: media.replycant.com/v1alpha1",
                "kind: Original",
                "metadata:",
                "  name: \(name)",
                "  deviceSpace: \(deviceSpace)",
                "spec:",
                "  id: \(name)",
                "  sha256: \(originalHash)",
                "  path: /test/path/\(name).\(fileExtension)",
                "  filesize: \(originalData.count)",
                "  mediaType: \(mediaType)",
                "  width: \(width)",
                "  height: \(height)"
            ]
            
            // Add duration field for videos
            if mediaType == "video" {
                manifestLines.append("  duration: \(videoDuration)")
            }
            
            manifestLines.append(contentsOf: [
                "  modifiedAt: \(timestamp)",
                "  mimeType: \(mimeType)",
                "  isFavorite: false",
                "  isHidden: false",
                "  takenAt: \(timestamp)",
                "  createdAt: \(timestamp)",
                "  clientCTime: \(timestamp)",
                "  guessedTakenAt: \(timestamp)",
                "status: {}"
            ])
            
            let originalManifest = try encryptManifestYAML(
                manifestLines.joined(separator: "\n"),
                kek: activeKEK,
                epoch: kekEpoch
            )
            
            filesToCommit.append((
                path: "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name)).yaml",
                content: originalManifest
            ))
            
            // Create LFS pointer for git tracking.
            let originalPointer: String
            if mediaType == "video" {
                originalPointer = """
                version https://git-lfs.github.com/spec/v1
                oid sha256:\(originalHash)
                size \(originalData.count)
                """
            } else {
                let encryptedOriginal = try encryptAndStore(
                    data: originalData,
                    kek: activeKEK,
                    kekEpoch: kekEpoch,
                    server: TestLFSServer.shared
                )
                originalPointer = EncryptedLFSPointer(
                    oid: encryptedOriginal.encryptedOID,
                    size: encryptedOriginal.encryptedSize,
                    kekEpoch: kekEpoch,
                    wrappedDEK: encryptedOriginal.wrappedDEK
                ).content
            }
            
            filesToCommit.append((
                path: "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name))",
                content: originalPointer
            ))
            
            let usesScreenshotPhoto = fixtureSeed.sourcePhoto != nil
            let thumbnailRecipes: [(name: String, recipe: ThumbnailRecipe)] = usesScreenshotPhoto
                ? [
                    ("150x150", .square(150)),
                    ("225x225", .square(225)),
                    ("1024", .maxDimension(1024))
                ]
                : (name.hasPrefix("o-")
                    ? [
                        ("150x150", .square(10)),
                        ("225x225", .square(10)),
                        ("1024", .square(10))
                    ]
                    : [
                        ("150x150", .square(150)),
                        ("225x225", .square(225)),
                        ("1024", .maxDimension(1024))
                    ])
            
            var thumbnailEntryLines: [String] = []
            for (sizeName, recipe) in thumbnailRecipes {
                let thumbnail: (data: Data, width: Int, height: Int)
                if usesScreenshotPhoto {
                    thumbnail = makeThumbnailJPEG(from: originalData, recipe: recipe)
                } else {
                    switch recipe {
                    case .square(let edge):
                        let syntheticData = createTestImageJPEG(width: edge, height: edge, name: name)
                        thumbnail = (syntheticData, edge, edge)
                    case .maxDimension:
                        let syntheticData = createTestImageJPEG(width: 1024, height: 768, name: name)
                        thumbnail = (syntheticData, 1024, 768)
                    }
                }
                let thumbnailData = thumbnail.data
                let thumbnailHash = calculateSHA256(data: thumbnailData)
                
                let encryptedThumbnail = try encryptAndStore(
                    data: thumbnailData,
                    kek: activeKEK,
                    kekEpoch: kekEpoch,
                    server: TestLFSServer.shared
                )
                
                let thumbnailName = "\(name)-thumb-\(sizeName)"
                thumbnailEntryLines.append("    - name: \(thumbnailName)")
                thumbnailEntryLines.append("      sha256: \(thumbnailHash)")
                thumbnailEntryLines.append("      width: \(thumbnail.width)")
                thumbnailEntryLines.append("      height: \(thumbnail.height)")
                thumbnailEntryLines.append("      filesize: \(thumbnailData.count)")
                
                let thumbnailPointer = EncryptedLFSPointer(
                    oid: encryptedThumbnail.encryptedOID,
                    size: encryptedThumbnail.encryptedSize,
                    kekEpoch: kekEpoch,
                    wrappedDEK: encryptedThumbnail.wrappedDEK
                ).content
                
                filesToCommit.append((
                    path: "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnailName))",
                    content: thumbnailPointer
                ))
            }
            let thumbnailSetManifest = try encryptManifestYAML(
                """
                apiVersion: media.replycant.com/v1alpha1
                kind: ThumbnailSet
                metadata:
                  name: \(name)-thumbs
                  deviceSpace: \(deviceSpace)
                spec:
                  originalRef: \(deviceSpace)/media.replycant.com/v1alpha1/Original/\(name)
                  thumbnails:
                \(thumbnailEntryLines.joined(separator: "\n"))
                status: {}
                """,
                kek: activeKEK,
                epoch: kekEpoch
            )

            filesToCommit.append((
                path: "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("\(name)-thumbs")).yaml",
                content: thumbnailSetManifest
            ))
        }
        
        // Commit all files (this commits the LFS pointers)
        try repo.createCommit(
            message: "Add test images for UI testing",
            files: filesToCommit
        )

        // Hydrates the shared manifest SQL cache asynchronously so timeline UI tests can load fixtures quickly.
        Task { @MainActor in
            do {
                RepositoryManager.shared.clearRepository()
                GitDBManager.shared.clearGitDB()
                try await ManifestLoaderManager.shared.deleteDatabaseFile()
                let gitDB = try GitDBManager.shared.getGitDB()
                try await gitDB.syncToHead(progressHandler: nil)
                await markFixturesReady()
                print("TestSupport: Manifest cache hydrated")
            } catch {
                fatalError("TestSupport: Failed to hydrate manifest cache: \(error)")
            }
        }
        
        print("TestSupport: Committed \(filesToCommit.count) files to repository")
        print("TestSupport: Created test repository with \(fixtureSeeds.count) items")
        
        // Debug: List all Original manifests that were created
        let originalManifests = filesToCommit.filter { $0.path.contains("/Original/") && $0.path.hasSuffix(".yaml") }
        print("TestSupport: Created \(originalManifests.count) Original manifests:")
        for manifest in originalManifests {
            let name = (manifest.path as NSString).lastPathComponent.replacingOccurrences(of: ".yaml", with: "")
            print("TestSupport:   - \(name)")
        }
        
        // Debug: List all ThumbnailSet manifests that were created
        let thumbnailManifests = filesToCommit.filter { $0.path.contains("/ThumbnailSet/") && $0.path.hasSuffix(".yaml") }
        print("TestSupport: Created \(thumbnailManifests.count) ThumbnailSet manifests")
    }
    
    @MainActor
    private static func markFixturesReady() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
            if let window {
                if window.viewWithTag(987654321) != nil {
                    return
                }
                let marker = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
                marker.tag = 987654321
                marker.isAccessibilityElement = true
                marker.accessibilityIdentifier = "uitest_fixtures_ready"
                marker.accessibilityLabel = "uitest_fixtures_ready"
                marker.isHidden = false
                marker.alpha = 0.02
                window.addSubview(marker)
                window.bringSubviewToFront(marker)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("TestSupport: Fixture marker window unavailable before timeout; continuing without marker")
    }

    private static func setupTestUserDefaults() {
        print("TestSupport: Setting up test UserDefaults")
        
        let lfsPort = TestLFSServer.shared.actualPort
        guard lfsPort > 0 else {
            fatalError("TestSupport: Test LFS server did not publish a valid listening port")
        }
        // Uses gitServerURL as the single source of truth; LFS URL is derived as {origin}/lfs.
        let testGitUrl = ProcessInfo.processInfo.environment["TEST_GIT_URL"] ?? "http://localhost:\(lfsPort)/repo.git"
        UserDefaults.standard.set(testGitUrl, forKey: "gitServerURL")

        print("TestSupport: Set Git URL to: \(testGitUrl)")
    }

    // Switches fixture strategy so screenshot runs use sanitized demo photos while regular UI tests keep deterministic synthetic media.
    static func shouldUseScreenshotFixtures(arguments: [String]) -> Bool {
        arguments.contains("--screenshots")
    }

    // Clears local repository/config leftovers so the privacy screenshot relaunch cannot reopen the seeded library.
    private static func resetLocalStateForScreenshotOnboarding() {
        print("TestSupport: Resetting local state for screenshot onboarding capture")
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let repoDir = documentsPath.appendingPathComponent("replycant-git-db")
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try? FileManager.default.removeItem(at: repoDir)
        }

        // Deletes on-disk SQLite caches directly so App.init stays free of MainActor manager calls.
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: supportDir,
            includingPropertiesForKeys: nil
        ) {
            for url in contents where url.lastPathComponent.contains("manifest") || url.pathExtension == "sqlite" {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "gitServerURL")
        defaults.removeObject(forKey: "hasCompletedOnboarding")
        defaults.synchronize()
    }

    // Cycles demo photos into a longer timeline so the App Store grid reads as a full library, not a short page.
    static func screenshotFixtureEntries(photoCount: Int, totalPhotoEntries: Int = 57) -> [ScreenshotFixtureEntry] {
        guard photoCount > 0 else { return [] }
        guard totalPhotoEntries > 0 else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let calendar = Calendar(identifier: .gregorian)
        let startDate = DateComponents(calendar: calendar, year: 2021, month: 1, day: 1).date ?? Date(timeIntervalSince1970: 0)
        let stepSeconds: TimeInterval = 60 * 60 * 24 * 30

        return (0..<totalPhotoEntries).map { index in
            let name = String(format: "p-%03d", index + 1)
            let date = startDate.addingTimeInterval(TimeInterval(index) * stepSeconds)
            let timestamp = isoFormatter.string(from: date)
            return ScreenshotFixtureEntry(
                name: name,
                timestamp: timestamp,
                sourceIndex: index % photoCount
            )
        }
    }

    // Resolves screenshot JPEG URLs from either a nested ScreenshotMedia folder or a flattened bundle root.
    // Xcode synchronized groups often copy resources flat, so discovery must accept both layouts.
    static func screenshotMediaURLs(in resourceRoot: URL) throws -> [URL] {
        let nestedDirectory = resourceRoot.appendingPathComponent("ScreenshotMedia", isDirectory: true)
        let searchRoots: [URL]
        if FileManager.default.fileExists(atPath: nestedDirectory.path) {
            searchRoots = [nestedDirectory]
        } else if FileManager.default.fileExists(atPath: resourceRoot.path) {
            searchRoots = [resourceRoot]
        } else {
            throw SetupError.missingScreenshotMediaDirectory
        }

        let mediaURLs = try searchRoots.flatMap { root in
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
        }
        .filter { url in
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()
            return (ext == "jpg" || ext == "jpeg") && name.hasPrefix("demo-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !mediaURLs.isEmpty else {
            throw SetupError.missingScreenshotMediaFiles
        }
        return mediaURLs
    }

    // Loads sanitized screenshot media from the app bundle to seed encrypted fixture repos with realistic photos.
    static func loadScreenshotMediaFromBundle() throws -> [ScreenshotFixturePhoto] {
        guard let resourceRoot = Bundle.main.resourceURL else {
            throw SetupError.missingScreenshotMediaDirectory
        }
        let mediaURLs = try screenshotMediaURLs(in: resourceRoot)

        return try mediaURLs.map { url in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                throw SetupError.failedToLoadScreenshotMedia(path: url.path)
            }
            return ScreenshotFixturePhoto(
                name: url.lastPathComponent,
                data: data,
                width: cgImage.width,
                height: cgImage.height
            )
        }
    }

    // Keeps screenshot fixture loading optional so normal UI tests continue using synthetic media without requiring bundled photos.
    private static func loadScreenshotMediaFromBundleIfNeeded(useScreenshotFixtures: Bool) throws -> [ScreenshotFixturePhoto] {
        guard useScreenshotFixtures else { return [] }
        return try loadScreenshotMediaFromBundle()
    }

    // Produces fixture seeds for either synthetic UI tests or screenshot capture runs without changing existing UITest defaults.
    private static func buildFixtureSeeds(
        useScreenshotFixtures: Bool,
        screenshotPhotos: [ScreenshotFixturePhoto]
    ) -> [FixtureSeed] {
        if useScreenshotFixtures, !screenshotPhotos.isEmpty {
            // Photos only: a leading video fixture would make App Store captures open a
            // buffering fullscreen player instead of a still image.
            return screenshotFixtureEntries(photoCount: screenshotPhotos.count).map { entry in
                FixtureSeed(
                    name: entry.name,
                    timestamp: entry.timestamp,
                    mediaType: "photo",
                    sourcePhoto: screenshotPhotos[entry.sourceIndex]
                )
            }
        }

        var seeds: [FixtureSeed] = (1...12).map { index in
            FixtureSeed(
                name: String(format: "o-%02d", index),
                timestamp: String(format: "2023-01-%02dT08:00:00Z", index),
                mediaType: "photo",
                sourcePhoto: nil
            )
        }
        seeds.append(contentsOf: [
            FixtureSeed(name: "i-1", timestamp: "2024-01-01T10:00:00Z", mediaType: "photo", sourcePhoto: nil),
            FixtureSeed(name: "i-2", timestamp: "2024-01-02T15:30:00Z", mediaType: "photo", sourcePhoto: nil),
            FixtureSeed(name: "i-3", timestamp: "2024-01-03T09:15:00Z", mediaType: "photo", sourcePhoto: nil),
            FixtureSeed(name: "v-1", timestamp: "2023-12-31T12:00:00Z", mediaType: "video", sourcePhoto: nil)
        ])
        return seeds
    }

    // Renders screenshot thumbnails with stable dimensions so App Store captures match production crop behavior.
    private static func makeThumbnailJPEG(
        from originalData: Data,
        recipe: ThumbnailRecipe
    ) -> (data: Data, width: Int, height: Int) {
        guard let image = UIImage(data: originalData),
              let cgImage = image.cgImage else {
            return (createMinimalJPEG(), 1, 1)
        }

        switch recipe {
        case .square(let edge):
            let cropped = centerCropSquare(cgImage: cgImage)
            let size = CGSize(width: edge, height: edge)
            let data = renderJPEG(cgImage: cropped, size: size)
            return (data, edge, edge)
        case .maxDimension(let maxDimension):
            let width = cgImage.width
            let height = cgImage.height
            let maxSide = max(width, height)
            if maxSide <= maxDimension {
                let data = renderJPEG(cgImage: cgImage, size: CGSize(width: width, height: height))
                return (data, width, height)
            }
            let scale = CGFloat(maxDimension) / CGFloat(maxSide)
            let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
            let data = renderJPEG(
                cgImage: cgImage,
                size: CGSize(width: targetWidth, height: targetHeight)
            )
            return (data, targetWidth, targetHeight)
        }
    }

    // Exposes screenshot thumbnail dimensions so tests can lock App Store fixture sizing behavior.
    static func screenshotThumbnailDimensions(for originalData: Data) -> [(name: String, width: Int, height: Int)] {
        [
            ("150x150", makeThumbnailJPEG(from: originalData, recipe: .square(150))),
            ("225x225", makeThumbnailJPEG(from: originalData, recipe: .square(225))),
            ("1024", makeThumbnailJPEG(from: originalData, recipe: .maxDimension(1024)))
        ].map { (name, thumb) in
            (name, thumb.width, thumb.height)
        }
    }

    // Center-crops to a square so small timeline thumbnails have consistent composition regardless of source aspect ratio.
    private static func centerCropSquare(cgImage: CGImage) -> CGImage {
        let side = min(cgImage.width, cgImage.height)
        let x = (cgImage.width - side) / 2
        let y = (cgImage.height - side) / 2
        let rect = CGRect(x: x, y: y, width: side, height: side)
        return cgImage.cropping(to: rect) ?? cgImage
    }

    // Encodes rendered thumbnails as JPEG so fixture blobs follow the same media type expectations as production photos.
    private static func renderJPEG(cgImage: CGImage, size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let renderedImage = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return renderedImage.jpegData(compressionQuality: 0.82) ?? createMinimalJPEG()
    }
    
    // Helper to create test JPEG image data with a simple pattern
    // This creates a valid JPEG that can be loaded by UIImage
    private static func createTestImageJPEG(width: Int, height: Int, name: String) -> Data {
        // Create a simple colored bitmap
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapData = UnsafeMutablePointer<UInt8>.allocate(capacity: height * bytesPerRow)
        defer { bitmapData.deallocate() }

        // Use md5 to hash the name string to an Int (for deterministic color patterns)
        let nameData = Data(name.utf8)
        let digest = Insecure.MD5.hash(data: nameData)
        let nameInt = digest.withUnsafeBytes {
            $0[0...3].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        // Fill with a simple gradient pattern based on name
        let hue = Float(abs(Int(nameInt) % 360)) / 360.0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let brightness = Float(y) / Float(height)
                let (r, g, b) = hsbToRgb(h: hue, s: 0.7, b: brightness * 0.5 + 0.5)
                bitmapData[offset] = UInt8(r * 255)
                bitmapData[offset + 1] = UInt8(g * 255)
                bitmapData[offset + 2] = UInt8(b * 255)
                bitmapData[offset + 3] = 255
            }
        }
        
        // Convert to UIImage and then to JPEG
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let context = CGContext(
            data: bitmapData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
        let cgImage = context.makeImage() else {
            // Fallback: create minimal valid JPEG
            return createMinimalJPEG()
        }
        
        // Draw text on the image
        let image = UIImage(cgImage: cgImage)
        let size = CGSize(width: width, height: height)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: size))
        
        let textContext = UIGraphicsGetCurrentContext()!
        textContext.setFillColor(UIColor.white.cgColor)
        textContext.setStrokeColor(UIColor.black.cgColor)
        textContext.setLineWidth(2.0)
        
        // Calculate bounding box that is 60% of canvas size, centered
        let boundingBoxWidth = CGFloat(width) * 0.6
        let boundingBoxHeight = CGFloat(height) * 0.6
        let boundingBoxX = (CGFloat(width) - boundingBoxWidth) / 2.0
        let boundingBoxY = (CGFloat(height) - boundingBoxHeight) / 2.0
        let boundingBox = CGRect(x: boundingBoxX, y: boundingBoxY, width: boundingBoxWidth, height: boundingBoxHeight)
        
        // Calculate font size to fit text within bounding box
        let font = UIFont.systemFont(ofSize: min(boundingBoxWidth, boundingBoxHeight) / CGFloat(max(name.count, 1)) * 0.8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -2.0
        ]
        
        let attributedString = NSAttributedString(string: name, attributes: attributes)
        let textSize = attributedString.size()
        let textRect = CGRect(
            x: boundingBox.midX - textSize.width / 2.0,
            y: boundingBox.midY - textSize.height / 2.0,
            width: textSize.width,
            height: textSize.height
        )
        
        attributedString.draw(in: textRect)
        
        let finalImage = UIGraphicsGetImageFromCurrentImageContext()!
        return finalImage.jpegData(compressionQuality: 0.8) ?? createMinimalJPEG()
    }
    
    // Helper to convert HSB to RGB
    private static func hsbToRgb(h: Float, s: Float, b: Float) -> (r: Float, g: Float, b: Float) {
        let c = b * s
        let x = c * (1 - abs(((h * 6).truncatingRemainder(dividingBy: 2)) - 1))
        let m = b - c
        
        let (r1, g1, b1): (Float, Float, Float)
        if h < 1.0/6.0 {
            (r1, g1, b1) = (c, x, 0)
        } else if h < 2.0/6.0 {
            (r1, g1, b1) = (x, c, 0)
        } else if h < 3.0/6.0 {
            (r1, g1, b1) = (0, c, x)
        } else if h < 4.0/6.0 {
            (r1, g1, b1) = (0, x, c)
        } else if h < 5.0/6.0 {
            (r1, g1, b1) = (x, 0, c)
        } else {
            (r1, g1, b1) = (c, 0, x)
        }
        
        return (r1 + m, g1 + m, b1 + m)
    }
    
    // Create a minimal valid JPEG (1x1 pixel) as fallback
    private static func createMinimalJPEG() -> Data {
        let size = CGSize(width: 1, height: 1)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()!
        context.setFillColor(UIColor.gray.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
    
    // Helper to calculate SHA256
    private static func calculateSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Wraps plaintext YAML in a REPLYCANT-ENC-V1 envelope so UITest sync rejects hostile plaintext blobs.
    private static func encryptManifestYAML(_ yaml: String, kek: Data, epoch: Int) throws -> String {
        let encrypted = try EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: kek)
        return """
        REPLYCANT-ENC-V1
        kek-epoch: \(epoch)
        ---
        \(encrypted.base64EncodedString())
        """
    }

    // Encrypts fixture blobs and stores ciphertext in the test LFS server so UI tests exercise real pointer decryption.
    private static func encryptAndStore(
        data: Data,
        kek: Data,
        kekEpoch: Int,
        server: TestLFSServer
    ) throws -> (encryptedOID: String, encryptedSize: Int64, wrappedDEK: String) {
        let dek = EncryptionUtils.randomKey(length: 32)
        let encryptedData = try EncryptionUtils.encryptChunkedBinary(
            plaintext: data,
            dek: dek
        )
        let wrappedDEK = try EncryptionUtils.wrapDEK(dek, withKEK: kek, kekEpoch: kekEpoch).base64EncodedString()
        let encryptedOID = calculateSHA256(data: encryptedData)
        server.store(oid: encryptedOID, data: encryptedData)
        return (
            encryptedOID: encryptedOID,
            encryptedSize: Int64(encryptedData.count),
            wrappedDEK: wrappedDEK
        )
    }
    
    // Generates a simple HLS media playlist with one segment pointing to the video file
    // The segment URL points to the video file served through TestLFSServer
    // The segment path is relative and will be resolved relative to the playlist URL
    static func generateHLSPlaylist(oid: String, duration: Double, resolution: String = "640x360") -> String {
        // Calculate target duration (round up to nearest integer)
        let targetDuration = Int(ceil(duration))
        
        // The segment URL is relative to the playlist URL
        // If playlist is at /hls/{oid}/{duration}/playlist.m3u8
        // Then segment.mp4 resolves to /hls/{oid}/{duration}/segment.mp4
        // Use media playlist format (not master playlist) for single-segment videos
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXTINF:\(duration),
        segment.mp4
        #EXT-X-ENDLIST
        """
        return playlist
    }
    
    // Loads video file from bundle and returns its data
    static func loadVideoFromBundle(filename: String) -> Data? {
        var url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "TestResources")
        url = url ?? Bundle.main.url(forResource: filename, withExtension: nil)
        
        if url == nil, let resourcePath = Bundle.main.resourcePath {
            let rootPath = (resourcePath as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: rootPath) {
                url = URL(fileURLWithPath: rootPath, isDirectory: false)
            }
        }
        
        guard let url = url else { return nil }
        
        return try? Data(contentsOf: url)
    }
    
    // Gets video duration from MP4 file (simple parser for test purposes)
    // For a 10-second test video, we can hardcode or parse basic MP4 metadata
    static func getVideoDuration(from data: Data) -> Double {
        // For Big_Buck_Bunny_360_10s_1MB.mp4, we know it's 10 seconds
        // In a real implementation, we'd parse the MP4 moov atom
        // For now, return 10.0 as the file name indicates 10s
        return 10.0
    }
}

// Mock implementation of ManifestLoaderProtocol for testing and previews
class MockManifestLoader: ManifestLoaderProtocol {
    private var originals: [OriginalManifest] = []
    private var thumbnails: [ThumbnailSetManifest] = []

    func setOriginals(_ manifests: [OriginalManifest]) {
        self.originals = manifests
    }

    func setThumbnails(_ manifests: [ThumbnailSetManifest]) {
        self.thumbnails = manifests
    }

    func loadManifest<T: Manifest>(deviceSpace: String?, id: String) async throws -> T? {
        if T.self == OriginalManifest.self {
            let filtered: [OriginalManifest]
            if let deviceSpace = deviceSpace {
                filtered = originals.filter { $0.metadata.deviceSpace == deviceSpace }
            } else {
                filtered = originals
            }
            return filtered.first { $0.spec.id == id } as? T
        } else if T.self == ThumbnailSetManifest.self {
            let filtered: [ThumbnailSetManifest]
            if let deviceSpace = deviceSpace {
                filtered = thumbnails.filter { $0.metadata.deviceSpace == deviceSpace }
            } else {
                filtered = thumbnails
            }
            return filtered.first { $0.id == id } as? T
        }
        return nil
    }

    func loadAllManifests<T: Manifest>(deviceSpace: String?) async throws -> [T] {
        if T.self == OriginalManifest.self {
            let filtered: [OriginalManifest]
            if let deviceSpace = deviceSpace {
                filtered = originals.filter { $0.metadata.deviceSpace == deviceSpace }
            } else {
                filtered = originals
            }
            return filtered as! [T]
        } else if T.self == ThumbnailSetManifest.self {
            let filtered: [ThumbnailSetManifest]
            if let deviceSpace = deviceSpace {
                filtered = thumbnails.filter { $0.metadata.deviceSpace == deviceSpace }
            } else {
                filtered = thumbnails
            }
            return filtered as! [T]
        }
        return []
    }

    // Counts timeline-visible originals in test fixtures so sparse timeline tests can size virtual ranges.
    func countTimelineOriginals() async throws -> Int {
        timelineOriginals().count
    }

    // Returns timeline originals by offset for sparse timeline tests without requiring a real database.
    func loadTimelinePage(offset: Int, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let sorted = timelineOriginals()
        guard offset < sorted.count else { return [] }
        let start = max(0, offset)
        let end = min(sorted.count, start + limit)
        return Array(sorted[start..<end])
    }

    // Returns originals older than cursor for sparse sequential-scroll tests in mock-driven flows.
    func loadTimelinePage(before: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let filtered = timelineOriginals().filter {
            guard let date = $0.spec.takenAt else { return false }
            return (date, $0.id) < (before.date, before.id)
        }
        return Array(filtered.suffix(limit))
    }

    // Returns originals newer than cursor for sparse sequential-scroll tests in mock-driven flows.
    func loadTimelinePage(after: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let filtered = timelineOriginals().filter {
            guard let date = $0.spec.takenAt else { return false }
            return (date, $0.id) > (after.date, after.id)
        }
        return Array(filtered.prefix(limit))
    }

    // Aggregates mock originals by year/month so month-sidebar tests can use the same query contract as production.
    func loadTimelineMonthCounts() async throws -> [TimelineMonthCount] {
        var grouped: [TimelineYearMonth: Int] = [:]
        let calendar = Calendar.current
        for original in timelineOriginals() {
            guard let date = original.spec.takenAt else { continue }
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

    // Resolves thumbnails by originalRef for sparse grid tests that expect O(1)-like batch lookup behavior.
    func loadThumbnailsByOriginalRefs(_ refs: [String]) async throws -> [String : ThumbnailSetManifest] {
        guard !refs.isEmpty else { return [:] }
        let refSet = Set(refs)
        var result: [String: ThumbnailSetManifest] = [:]
        for thumbnail in thumbnails where refSet.contains(thumbnail.spec.originalRef) {
            result[thumbnail.spec.originalRef] = thumbnail
        }
        return result
    }

    // Produces a deterministic timeline-sorted original list mirroring database ordering semantics.
    private func timelineOriginals() -> [OriginalManifest] {
        return originals
            .filter { $0.spec.takenAt != nil }
            .sorted {
                let leftDate = $0.spec.takenAt ?? .distantPast
                let rightDate = $1.spec.takenAt ?? .distantPast
                if leftDate == rightDate {
                    return $0.id < $1.id
                }
                return leftDate < rightDate
            }
    }
}

#endif


