import Foundation
import Testing
@testable import iosapp
import LibGit2

// Test fixture manager for setting up git repositories and test data
@MainActor
class TestFixtures {
    // Shards fixture filenames so tests validate the same git layout used in production.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }

    // Creates first-epoch encryption files and returns the active KEK for encrypting fixture manifests.
    private func bootstrapEncryptionFiles(in repo: Repository) throws -> (files: [(path: String, content: String)], kek: Data, epoch: Int) {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "iosapp-tests")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let manager = KEKEpochManager(repository: repo)
        let files = try manager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        let kek = try manager.loadKEK(epoch: 1)
        return (files, kek, 1)
    }

    // Wraps plaintext YAML in a REPLYCANT-ENC-V1 envelope so fixture repos match production at-rest encryption.
    private func encryptManifestYAML(_ yaml: String, kek: Data, epoch: Int) throws -> String {
        let encrypted = try EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: kek)
        return """
        REPLYCANT-ENC-V1
        kek-epoch: \(epoch)
        ---
        \(encrypted.base64EncodedString())
        """
    }

    // Creates a test git repository with sample images and thumbnails
    func setupTestRepository() throws -> (repoPath: String, lfsServer: MockLFSServer) {
        let tempDir = NSTemporaryDirectory()
        let testRepoName = "test-repo-\(UUID().uuidString)"
        let repoPath = (tempDir as NSString).appendingPathComponent(testRepoName)
        
        try? FileManager.default.removeItem(atPath: repoPath)
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        
        try Git.initialize()
        let repo = try Repository.create(at: repoPath, bare: false)
        
        // Create mock LFS server
        let lfsServer = MockLFSServer()
        
        // Create test device space
        let deviceSpace = "test-device-space"
        
        // Create directory structure
        let manifestDir = (repoPath as NSString).appendingPathComponent("manifests/\(deviceSpace)/media.replycant.com/v1alpha1")
        let originalManifestDir = (manifestDir as NSString).appendingPathComponent("Original")
        let thumbnailManifestDir = (manifestDir as NSString).appendingPathComponent("ThumbnailSet")
        let binaryDir = (repoPath as NSString).appendingPathComponent("binary/\(deviceSpace)/media.replycant.com/v1alpha1")
        let originalBinaryDir = (binaryDir as NSString).appendingPathComponent("Original")
        let thumbnailBinaryDir = (binaryDir as NSString).appendingPathComponent("ThumbnailSet")
        
        try FileManager.default.createDirectory(atPath: originalManifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: thumbnailManifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: originalBinaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: thumbnailBinaryDir, withIntermediateDirectories: true)
        
        // Create test images
        let testImages = [
            ("i-1", createTestImageData(size: CGSize(width: 1920, height: 1080)), "2024-01-01T10:00:00Z"),
            ("i-2", createTestImageData(size: CGSize(width: 1080, height: 1920)), "2024-01-02T15:30:00Z"),
            ("i-3", createTestImageData(size: CGSize(width: 2048, height: 1536)), "2024-01-03T09:15:00Z")
        ]
        
        let bootstrap = try bootstrapEncryptionFiles(in: repo)
        var filesToCommit: [(path: String, content: String)] = bootstrap.files
        
        for (name, imageData, timestamp) in testImages {
            // Calculate hash for original image
            let originalHash = MockLFSServer.calculateSHA256(data: imageData)
            
            // Store in mock LFS server
            lfsServer.store(oid: originalHash, data: imageData)
            
            // Create original manifest
            let originalManifest = try encryptManifestYAML(
                """
                apiVersion: media.replycant.com/v1alpha1
                kind: Original
                metadata:
                  name: \(name)
                  deviceSpace: \(deviceSpace)
                spec:
                  id: \(name)
                  sha256: \(originalHash)
                  path: /test/path/\(name).jpg
                  filesize: \(imageData.count)
                  mediaType: photo
                  width: 1920
                  height: 1080
                  modifiedAt: \(timestamp)
                  mimeType: image/jpeg
                  isFavorite: false
                  isHidden: false
                  createdAt: \(timestamp)
                  takenAt: \(timestamp)
                  clientCTime: \(timestamp)
                  guessedTakenAt: \(timestamp)
                status: {}
                """,
                kek: bootstrap.kek,
                epoch: bootstrap.epoch
            )
            
            let originalManifestPath = "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name)).yaml"
            filesToCommit.append((path: originalManifestPath, content: originalManifest))
            
            // Create LFS pointer for original
            let originalPointer = """
            version https://git-lfs.github.com/spec/v1
            oid sha256:\(originalHash)
            size \(imageData.count)
            """
            
            let originalPointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name))"
            filesToCommit.append((path: originalPointerPath, content: originalPointer))
            
            // Create thumbnails with different sizes
            let thumbnailSizes: [(name: String, width: Int, height: Int)] = [
                ("150x150", 150, 150),
                ("225x225", 225, 225),
                ("1024", 1024, 768)
            ]
            var thumbnailEntryLines: [String] = []
            for (sizeName, width, height) in thumbnailSizes {
                let thumbnailData = createTestImageData(size: CGSize(width: width, height: height))
                let thumbnailHash = MockLFSServer.calculateSHA256(data: thumbnailData)
                
                lfsServer.store(oid: thumbnailHash, data: thumbnailData)
                
                let thumbnailName = "\(name)-thumb-\(sizeName)"
                thumbnailEntryLines.append("    - name: \(thumbnailName)")
                thumbnailEntryLines.append("      sha256: \(thumbnailHash)")
                thumbnailEntryLines.append("      width: \(width)")
                thumbnailEntryLines.append("      height: \(height)")
                thumbnailEntryLines.append("      filesize: \(thumbnailData.count)")
                
                let thumbnailPointer = """
                version https://git-lfs.github.com/spec/v1
                oid sha256:\(thumbnailHash)
                size \(thumbnailData.count)
                """
                
                let thumbnailPointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnailName))"
                filesToCommit.append((path: thumbnailPointerPath, content: thumbnailPointer))
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
                kek: bootstrap.kek,
                epoch: bootstrap.epoch
            )
            let thumbnailManifestPath = "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("\(name)-thumbs")).yaml"
            filesToCommit.append((path: thumbnailManifestPath, content: thumbnailSetManifest))
        }
        
        // Commit all files
        try repo.createCommit(
            message: "Add test images and thumbnails",
            files: filesToCommit
        )
        
        return (repoPath, lfsServer)
    }
    
    // Creates a test git repository with sample images and thumbnails across multiple device spaces
    func setupMultiDeviceTestRepository() throws -> (repoPath: String, lfsServer: MockLFSServer) {
        let tempDir = NSTemporaryDirectory()
        let testRepoName = "multi-test-repo-\(UUID().uuidString)"
        let repoPath = (tempDir as NSString).appendingPathComponent(testRepoName)
        
        try? FileManager.default.removeItem(atPath: repoPath)
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        
        try Git.initialize()
        let repo = try Repository.create(at: repoPath, bare: false)
        
        // Create mock LFS server
        let lfsServer = MockLFSServer()
        
        // Create two device spaces with different images
        let deviceSpaces = [
            ("device-space-1", [("i-1", "2024-01-01T10:00:00Z"), ("i-2", "2024-01-02T15:30:00Z")]),
            ("device-space-2", [("i-3", "2024-01-03T09:15:00Z"), ("i-4", "2024-01-04T14:20:00Z")])
        ]
        
        let bootstrap = try bootstrapEncryptionFiles(in: repo)
        var filesToCommit: [(path: String, content: String)] = bootstrap.files
        
        for (deviceSpace, images) in deviceSpaces {
            // Create directory structure
            let manifestDir = (repoPath as NSString).appendingPathComponent("manifests/\(deviceSpace)/media.replycant.com/v1alpha1")
            let originalManifestDir = (manifestDir as NSString).appendingPathComponent("Original")
            let thumbnailManifestDir = (manifestDir as NSString).appendingPathComponent("ThumbnailSet")
            let binaryDir = (repoPath as NSString).appendingPathComponent("binary/\(deviceSpace)/media.replycant.com/v1alpha1")
            let originalBinaryDir = (binaryDir as NSString).appendingPathComponent("Original")
            let thumbnailBinaryDir = (binaryDir as NSString).appendingPathComponent("ThumbnailSet")
            
            try FileManager.default.createDirectory(atPath: originalManifestDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: thumbnailManifestDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: originalBinaryDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: thumbnailBinaryDir, withIntermediateDirectories: true)
            
            for (name, timestamp) in images {
                let imageData = createTestImageData(size: CGSize(width: 1920, height: 1080))
                let originalHash = MockLFSServer.calculateSHA256(data: imageData)
                
                // Store in mock LFS server
                lfsServer.store(oid: originalHash, data: imageData)
                
                // Create original manifest
                let originalManifest = try encryptManifestYAML(
                    """
                    apiVersion: media.replycant.com/v1alpha1
                    kind: Original
                    metadata:
                      name: \(name)
                      deviceSpace: \(deviceSpace)
                    spec:
                      id: \(name)
                      sha256: \(originalHash)
                      path: /test/path/\(name).jpg
                      filesize: \(imageData.count)
                      mediaType: photo
                      width: 1920
                      height: 1080
                      modifiedAt: \(timestamp)
                      mimeType: image/jpeg
                      isFavorite: false
                      isHidden: false
                      createdAt: \(timestamp)
                      takenAt: \(timestamp)
                      clientCTime: \(timestamp)
                      guessedTakenAt: \(timestamp)
                    status: {}
                    """,
                    kek: bootstrap.kek,
                    epoch: bootstrap.epoch
                )
                
                let originalManifestPath = "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name)).yaml"
                filesToCommit.append((path: originalManifestPath, content: originalManifest))
                
                // Create LFS pointer for original
                let originalPointer = """
                version https://git-lfs.github.com/spec/v1
                oid sha256:\(originalHash)
                size \(imageData.count)
                """
                
                let originalPointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(name))"
                filesToCommit.append((path: originalPointerPath, content: originalPointer))
                
                // Create thumbnails with different sizes
                let thumbnailSizes: [(name: String, width: Int, height: Int)] = [
                    ("150x150", 150, 150),
                    ("225x225", 225, 225),
                    ("1024", 1024, 768)
                ]
                var thumbnailEntryLines: [String] = []
                for (sizeName, width, height) in thumbnailSizes {
                    let thumbnailData = createTestImageData(size: CGSize(width: width, height: height))
                    let thumbnailHash = MockLFSServer.calculateSHA256(data: thumbnailData)
                    
                    lfsServer.store(oid: thumbnailHash, data: thumbnailData)
                    
                    let thumbnailName = "\(name)-thumb-\(sizeName)"
                    thumbnailEntryLines.append("    - name: \(thumbnailName)")
                    thumbnailEntryLines.append("      sha256: \(thumbnailHash)")
                    thumbnailEntryLines.append("      width: \(width)")
                    thumbnailEntryLines.append("      height: \(height)")
                    thumbnailEntryLines.append("      filesize: \(thumbnailData.count)")
                    
                    let thumbnailPointer = """
                    version https://git-lfs.github.com/spec/v1
                    oid sha256:\(thumbnailHash)
                    size \(thumbnailData.count)
                    """
                    
                    let thumbnailPointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnailName))"
                    filesToCommit.append((path: thumbnailPointerPath, content: thumbnailPointer))
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
                    kek: bootstrap.kek,
                    epoch: bootstrap.epoch
                )
                let thumbnailManifestPath = "manifests/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("\(name)-thumbs")).yaml"
                filesToCommit.append((path: thumbnailManifestPath, content: thumbnailSetManifest))
            }
        }
        
        // Commit all files
        try repo.createCommit(
            message: "Add test images and thumbnails across multiple device spaces",
            files: filesToCommit
        )
        
        return (repoPath, lfsServer)
    }
    
    // Clean up test repository at specified path
    func cleanupTestRepository(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    // Create a simple test image data (minimal JPEG-like data)
    private func createTestImageData(size: CGSize) -> Data {
        // Create simple test data that represents an image
        // This is just mock data for testing - actual image encoding not required
        let pixelCount = Int(size.width * size.height * 3)
        var data = Data(count: pixelCount)
        
        // Fill with a pattern that varies by size to make images distinguishable
        let seed = Int(size.width) * 1000 + Int(size.height)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            for i in 0..<pixelCount {
                ptr[i] = UInt8((i + seed) % 256)
            }
        }
        
        return data
    }
}

