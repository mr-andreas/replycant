import Foundation
import Testing
@testable import iosapp
import LibGit2

// Comprehensive tests for GitCommitService covering commit operations, path generation,
// content validation, and edge cases to ensure reliable manifest and LFS pointer commits.
@MainActor
@Suite(.sharedAppState)
struct GitCommitServiceTests {
    // Shards expected manifest and pointer filenames so assertions mirror production git layout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }

    // Builds a commit-ready encrypted pointer so tests exercise GitDB's
    // pointer type without depending on LibGit2 encryption fields.
    private func encryptedPointer(oid: String, size: Int64) -> EncryptedLFSPointer {
        EncryptedLFSPointer(oid: oid, size: size, kekEpoch: 1, wrappedDEK: "dGVzdA==")
    }

    // Converts workdir absolute paths used in legacy tests into repository-relative HEAD paths.
    private func treePath(fromAbsolutePath absolutePath: String, workdir: String) -> String {
        let prefix = workdir.hasSuffix("/") ? workdir : "\(workdir)/"
        return absolutePath.hasPrefix(prefix) ? String(absolutePath.dropFirst(prefix.count)) : absolutePath
    }

    // Resolves file existence from the git tree without touching the checked-out working directory.
    private func repoFileExists(_ repo: Repository, workdir: String, absolutePath: String) -> Bool {
        repo.fileExists(at: treePath(fromAbsolutePath: absolutePath, workdir: workdir))
    }

    // Reads file content from the git tree without requiring a workdir checkout.
    private func readRepoFile(_ repo: Repository, workdir: String, absolutePath: String) throws -> String {
        try repo.readFile(at: treePath(fromAbsolutePath: absolutePath, workdir: workdir))
    }

    // Validates encrypted manifest storage format so tests assert ciphertext at rest rather than plaintext YAML.
    private func assertEncryptedManifestEnvelope(_ content: String) throws {
        let lines = content.components(separatedBy: .newlines)
        #expect(lines.count >= 4)
        #expect(lines[0] == "REPLYCANT-ENC-V1")
        #expect(lines[1].hasPrefix("kek-epoch: "))
        #expect(lines[2] == "---")
        let payload = lines[3].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!payload.isEmpty)
        #expect(Data(base64Encoded: payload) != nil)
    }
    
    // MARK: - Basic Commit Operations
    
    @Test func testSingleManifestCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "test-image-1",
            localID: "local_ID/test-image-1",
            sha256: "abc123def456",
            path: "/test/image.jpg",
            filesize: 12345,
            name: "test-image-1",
            deviceSpace: "test-device",
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
            createdAt: Date(),
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )
        
        try await service.createCommit(
            message: "Add test image manifest",
            items: [.manifest(manifest)]
        )
        
        let workdir = try #require(repo.workdir)
        let manifestPath = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("test-image-1")).yaml"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: manifestPath))
        
        let content = try readRepoFile(repo, workdir: workdir, absolutePath: manifestPath)
        try assertEncryptedManifestEnvelope(content)
    }
    
    @Test func testMultipleManifestCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let originalManifest = OriginalManifest(
            id: "orig-1",
            localID: "local_ID/orig-1",
            sha256: "aaa111",
            path: "/test/orig.jpg",
            filesize: 10000,
            name: "orig-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: "2024-01-01T10:00:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let thumbnailManifest = ThumbnailSetManifest(
            originalRef: "test-device/media.replycant.com/v1alpha1/Original/orig-1",
            thumbnails: [
                .init(name: "thumb-1", sha256: "bbb222", width: 150, height: 150, filesize: 1000),
            ],
            name: "thumb-1",
            deviceSpace: "test-device"
        )
        
        try await service.createCommit(
            message: "Add original and thumbnail",
            items: [.manifest(originalManifest), .manifest(thumbnailManifest)]
        )
        
        let workdir = try #require(repo.workdir)
        
        let origPath = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("orig-1")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: origPath))
        
        let thumbPath = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("thumb-1")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: thumbPath))
        
        let origContent = try readRepoFile(repo, workdir: workdir, absolutePath: origPath)
        try assertEncryptedManifestEnvelope(origContent)
        
        let thumbContent = try readRepoFile(repo, workdir: workdir, absolutePath: thumbPath)
        try assertEncryptedManifestEnvelope(thumbContent)
    }
    
    @Test func testSingleLFSPointerCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "lfs-test-1",
            localID: "local_ID/lfs-test-1",
            sha256: "fff999",
            path: "/test/lfs.jpg",
            filesize: 50000,
            name: "lfs-test-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 2048,
            height: 1536,
            modifiedAt: "2024-01-01T10:00:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let pointer = encryptedPointer(oid: "abc123def456789012345678901234567890123456789012345678901234", size: 50000)
        
        try await service.createCommit(
            message: "Add LFS pointer",
            items: [.lfs(forManifest: manifest, pointer: pointer)]
        )
        
        let workdir = try #require(repo.workdir)
        let pointerPath = (workdir as NSString).appendingPathComponent(
            "binary/test-device/media.replycant.com/v1alpha1/Original/\(shardName("lfs-test-1"))"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: pointerPath))
        
        let content = try readRepoFile(repo, workdir: workdir, absolutePath: pointerPath)
        #expect(content.contains("version https://git-lfs.github.com/spec/v1"))
        #expect(content.contains("oid sha256:abc123def456789012345678901234567890123456789012345678901234"))
        #expect(content.contains("size 50000"))
    }
    
    @Test func testMultipleLFSPointerCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest1 = OriginalManifest(
            id: "lfs-1",
            localID: "local_ID/lfs-1",
            sha256: "hash1",
            path: "/test/1.jpg",
            filesize: 10000,
            name: "lfs-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let manifest2 = OriginalManifest(
            id: "lfs-2",
            localID: "local_ID/lfs-2",
            sha256: "hash2",
            path: "/test/2.jpg",
            filesize: 20000,
            name: "lfs-2",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let pointer1 = encryptedPointer(oid: "1111111111111111111111111111111111111111111111111111111111111111", size: 10000)
        let pointer2 = encryptedPointer(oid: "2222222222222222222222222222222222222222222222222222222222222222", size: 20000)
        
        try await service.createCommit(
            message: "Add multiple LFS pointers",
            items: [
                .lfs(forManifest: manifest1, pointer: pointer1),
                .lfs(forManifest: manifest2, pointer: pointer2)
            ]
        )
        
        let workdir = try #require(repo.workdir)
        
        let path1 = (workdir as NSString).appendingPathComponent(
            "binary/test-device/media.replycant.com/v1alpha1/Original/\(shardName("lfs-1"))"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path1))
        
        let path2 = (workdir as NSString).appendingPathComponent(
            "binary/test-device/media.replycant.com/v1alpha1/Original/\(shardName("lfs-2"))"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path2))
        
        let content1 = try readRepoFile(repo, workdir: workdir, absolutePath: path1)
        #expect(content1.contains("size 10000"))
        
        let content2 = try readRepoFile(repo, workdir: workdir, absolutePath: path2)
        #expect(content2.contains("size 20000"))
    }
    
    @Test func testMixedCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "mixed-1",
            localID: "local_ID/mixed-1",
            sha256: "mixhash",
            path: "/test/mixed.jpg",
            filesize: 15000,
            name: "mixed-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let pointer = encryptedPointer(oid: "9999999999999999999999999999999999999999999999999999999999999999", size: 15000)
        
        try await service.createCommit(
            message: "Add manifest and LFS pointer together",
            items: [
                .manifest(manifest),
                .lfs(forManifest: manifest, pointer: pointer)
            ]
        )
        
        let workdir = try #require(repo.workdir)
        
        let manifestPath = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("mixed-1")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: manifestPath))
        
        let pointerPath = (workdir as NSString).appendingPathComponent(
            "binary/test-device/media.replycant.com/v1alpha1/Original/\(shardName("mixed-1"))"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: pointerPath))
    }
    
    // MARK: - Path Generation Tests
    
    @Test func testOriginalManifestPathGeneration() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "my-device-space", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "path-test-orig",
            localID: "local_ID/path-test-orig",
            sha256: "pathhash",
            path: "/test/path.jpg",
            filesize: 1000,
            name: "path-test-orig",
            deviceSpace: "my-device-space",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "Test path", items: [.manifest(manifest)])
        
        let workdir = try #require(repo.workdir)
        let expectedPath = (workdir as NSString).appendingPathComponent(
            "manifests/my-device-space/media.replycant.com/v1alpha1/Original/\(shardName("path-test-orig")).yaml"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: expectedPath))
    }
    
    @Test func testThumbnailSetManifestPathGeneration() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "my-device-space", lfsClient: lfs)
        
        let manifest = ThumbnailSetManifest(
            originalRef: "my-device-space/media.replycant.com/v1alpha1/Original/some-id",
            thumbnails: [
                .init(name: "path-test-thumb", sha256: "thumbhash", width: 150, height: 150, filesize: 500),
            ],
            name: "path-test-thumb",
            deviceSpace: "my-device-space"
        )
        
        try await service.createCommit(message: "Test path", items: [.manifest(manifest)])
        
        let workdir = try #require(repo.workdir)
        let expectedPath = (workdir as NSString).appendingPathComponent(
            "manifests/my-device-space/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("path-test-thumb")).yaml"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: expectedPath))
    }
    
    @Test func testOriginalLFSPathGeneration() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "my-device-space", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "lfs-path-orig",
            localID: "local_ID/lfs-path-orig",
            sha256: "lfshash",
            path: "/test/lfs.jpg",
            filesize: 2000,
            name: "lfs-path-orig",
            deviceSpace: "my-device-space",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let pointer = encryptedPointer(oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", size: 2000)
        
        try await service.createCommit(
            message: "Test LFS path",
            items: [.lfs(forManifest: manifest, pointer: pointer)]
        )
        
        let workdir = try #require(repo.workdir)
        let expectedPath = (workdir as NSString).appendingPathComponent(
            "binary/my-device-space/media.replycant.com/v1alpha1/Original/\(shardName("lfs-path-orig"))"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: expectedPath))
    }
    
    @Test func testThumbnailSetLFSPathGeneration() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "my-device-space", lfsClient: lfs)
        
        let pointer = encryptedPointer(oid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", size: 1500)
        
        try await service.createCommit(
            message: "Test LFS path",
            items: [
                .lfsEntry(
                    apiVersion: "media.replycant.com/v1alpha1",
                    kind: "ThumbnailSet",
                    name: "lfs-path-thumb",
                    pointer: pointer
                ),
            ]
        )
        
        let workdir = try #require(repo.workdir)
        let expectedPath = (workdir as NSString).appendingPathComponent(
            "binary/my-device-space/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("lfs-path-thumb"))"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: expectedPath))
    }
    
    @Test func testDeviceSpaceIsolation() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service1 = DefaultGitCommitService(repository: repo, deviceSpace: "device-1", lfsClient: lfs)
        let service2 = DefaultGitCommitService(repository: repo, deviceSpace: "device-2", lfsClient: lfs)
        
        let manifest1 = OriginalManifest(
            id: "iso-test",
            localID: "local_ID/iso-test",
            sha256: "hash1",
            path: "/test/1.jpg",
            filesize: 1000,
            name: "iso-test",
            deviceSpace: "device-1",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let manifest2 = OriginalManifest(
            id: "iso-test",
            localID: "local_ID/iso-test",
            sha256: "hash2",
            path: "/test/2.jpg",
            filesize: 2000,
            name: "iso-test",
            deviceSpace: "device-2",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service1.createCommit(message: "Device 1", items: [.manifest(manifest1)])
        try await service2.createCommit(message: "Device 2", items: [.manifest(manifest2)])
        
        let workdir = try #require(repo.workdir)
        
        let path1 = (workdir as NSString).appendingPathComponent(
            "manifests/device-1/media.replycant.com/v1alpha1/Original/\(shardName("iso-test")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path1))
        
        let path2 = (workdir as NSString).appendingPathComponent(
            "manifests/device-2/media.replycant.com/v1alpha1/Original/\(shardName("iso-test")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path2))
        
        let content1 = try readRepoFile(repo, workdir: workdir, absolutePath: path1)
        try assertEncryptedManifestEnvelope(content1)
        
        let content2 = try readRepoFile(repo, workdir: workdir, absolutePath: path2)
        try assertEncryptedManifestEnvelope(content2)
    }
    
    // MARK: - Content Validation Tests
    
    @Test func testYAMLEncodingStructure() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "yaml-test",
            localID: "local_ID/yaml-test",
            sha256: "yamlhash123",
            path: "/test/yaml.jpg",
            filesize: 98765,
            name: "yaml-test",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: "2024-01-15T14:30:00Z",
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: true,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "Test YAML", items: [.manifest(manifest)])
        
        let workdir = try #require(repo.workdir)
        let manifestPath = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("yaml-test")).yaml"
        )
        
        let content = try readRepoFile(repo, workdir: workdir, absolutePath: manifestPath)
        try assertEncryptedManifestEnvelope(content)
    }
    
    @Test func testLFSPointerFormat() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "lfs-format-test",
            localID: "local_ID/lfs-format-test",
            sha256: "formathash",
            path: "/test/format.jpg",
            filesize: 123456,
            name: "lfs-format-test",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let testOid = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        let pointer = EncryptedLFSPointer(
            oid: testOid,
            size: 123456,
            kekEpoch: 2,
            wrappedDEK: "d3JhcHBlZA=="
        )
        
        try await service.createCommit(
            message: "Test LFS format",
            items: [.lfs(forManifest: manifest, pointer: pointer)]
        )
        
        let workdir = try #require(repo.workdir)
        let pointerPath = (workdir as NSString).appendingPathComponent(
            "binary/test-device/media.replycant.com/v1alpha1/Original/\(shardName("lfs-format-test"))"
        )
        
        let content = try readRepoFile(repo, workdir: workdir, absolutePath: pointerPath)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        #expect(lines.count == 5)
        #expect(lines[0] == "version https://git-lfs.github.com/spec/v1")
        #expect(lines[1] == "oid sha256:\(testOid)")
        #expect(lines[2] == "size 123456")
        #expect(lines[3] == "x-replycant-kek-epoch 2")
        #expect(lines[4] == "x-replycant-wrapped-dek d3JhcHBlZA==")
    }
    
    @Test func testCommitMessagePreserved() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "commit-msg-test",
            localID: "local_ID/commit-msg-test",
            sha256: "msghash",
            path: "/test/msg.jpg",
            filesize: 1000,
            name: "commit-msg-test",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let customMessage = "Custom commit message for testing purposes"
        try await service.createCommit(message: customMessage, items: [.manifest(manifest)])
        
        let status = repo.getStatus()
        #expect(!status.isEmpty)
    }
    
    // MARK: - Sequential Operations Tests
    
    @Test func testMultipleSequentialCommits() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest1 = OriginalManifest(
            id: "seq-1",
            localID: "local_ID/seq-1",
            sha256: "hash1",
            path: "/test/1.jpg",
            filesize: 1000,
            name: "seq-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "First commit", items: [.manifest(manifest1)])
        
        let manifest2 = OriginalManifest(
            id: "seq-2",
            localID: "local_ID/seq-2",
            sha256: "hash2",
            path: "/test/2.jpg",
            filesize: 2000,
            name: "seq-2",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "Second commit", items: [.manifest(manifest2)])
        
        let manifest3 = OriginalManifest(
            id: "seq-3",
            localID: "local_ID/seq-3",
            sha256: "hash3",
            path: "/test/3.jpg",
            filesize: 3000,
            name: "seq-3",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "Third commit", items: [.manifest(manifest3)])
        
        let workdir = try #require(repo.workdir)
        
        let path1 = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("seq-1")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path1))
        
        let path2 = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("seq-2")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path2))
        
        let path3 = (workdir as NSString).appendingPathComponent(
            "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("seq-3")).yaml"
        )
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: path3))
    }
    
    @Test func testRepositoryStateAccumulation() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "accumulation-test", lfsClient: lfs)
        
        for i in 1...5 {
            let manifest = OriginalManifest(
                id: "accum-\(i)",
                localID: "local_ID/accum-\(i)",
                sha256: "hash\(i)",
                path: "/test/\(i).jpg",
                filesize: Int64(i * 1000),
                name: "accum-\(i)",
                deviceSpace: "accumulation-test",
                mediaType: "photo",
                width: 100,
                height: 100,
                modifiedAt: nil,
                duration: nil,
                mimeType: nil,
                location: nil,
                isFavorite: false,
                isHidden: false,
                burstIdentifier: nil
            )
            
            try await service.createCommit(message: "Commit \(i)", items: [.manifest(manifest)])
        }
        
        let workdir = try #require(repo.workdir)
        let manifestDir = (workdir as NSString).appendingPathComponent(
            "manifests/accumulation-test/media.replycant.com/v1alpha1/Original"
        )
        let manifestShardDir = (manifestDir as NSString).appendingPathComponent(
            "ac/cu"
        )
        
        let files = try repo.listFiles(in: treePath(fromAbsolutePath: manifestShardDir, workdir: workdir))
        #expect(files.count == 5)
        
        for i in 1...5 {
            let path = (manifestDir as NSString).appendingPathComponent(shardName("accum-\(i).yaml"))
            #expect(repoFileExists(repo, workdir: workdir, absolutePath: path))
        }
    }
    
    // MARK: - Edge Cases Tests
    
    @Test func testEmptyItemsArray() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        try await service.createCommit(message: "Empty commit", items: [])
        
        let status = repo.getStatus()
        #expect(!status.isEmpty)
    }
    
    @Test func testLongDeviceSpaceName() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let longDeviceSpace = "very-long-device-space-name-with-many-characters-for-testing-edge-cases"
        let service = DefaultGitCommitService(repository: repo, deviceSpace: longDeviceSpace, lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "long-space-test",
            localID: "local_ID/long-space-test",
            sha256: "longhash",
            path: "/test/long.jpg",
            filesize: 1000,
            name: "long-space-test",
            deviceSpace: longDeviceSpace,
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        try await service.createCommit(message: "Long space test", items: [.manifest(manifest)])
        
        let workdir = try #require(repo.workdir)
        let manifestPath = (workdir as NSString).appendingPathComponent(
            "manifests/\(longDeviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName("long-space-test")).yaml"
        )
        
        #expect(repoFileExists(repo, workdir: workdir, absolutePath: manifestPath))
    }
    
    @Test func testSpecialCharactersInID() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let specialIDs = [
            "id-with-dashes",
            "id123with456numbers"
        ]
        
        for specialID in specialIDs {
            let manifest = OriginalManifest(
                id: specialID,
                localID: "local_ID/\(specialID)",
                sha256: "specialhash",
                path: "/test/special.jpg",
                filesize: 1000,
                name: specialID,
                deviceSpace: "test-device",
                mediaType: "photo",
                width: 100,
                height: 100,
                modifiedAt: nil,
                duration: nil,
                mimeType: nil,
                location: nil,
                isFavorite: false,
                isHidden: false,
                burstIdentifier: nil
            )
            
            try await service.createCommit(
                message: "Special ID: \(specialID)",
                items: [.manifest(manifest)]
            )
            
            let workdir = try #require(repo.workdir)
            let manifestPath = (workdir as NSString).appendingPathComponent(
                "manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName(specialID)).yaml"
            )
            
            #expect(repoFileExists(repo, workdir: workdir, absolutePath: manifestPath))
        }
    }
    
    // MARK: - Manifest Name Validation Tests
    
    struct ManifestNameTestCase {
        let name: String
        let isValid: Bool
        let description: String
    }
    
    @Test func testManifestNameValidation() async throws {
        let testCases = [
            ManifestNameTestCase(name: "a", isValid: true, description: "single letter"),
            ManifestNameTestCase(name: "test-image-123", isValid: true, description: "with hyphens"),
            ManifestNameTestCase(name: "image123", isValid: true, description: "with numbers"),
            ManifestNameTestCase(name: "a" + String(repeating: "b", count: 249), isValid: true, description: "max length (250 chars)"),
            ManifestNameTestCase(name: "InvalidName", isValid: false, description: "starts with uppercase"),
            ManifestNameTestCase(name: "123image", isValid: false, description: "starts with digit"),
            ManifestNameTestCase(name: "-image", isValid: false, description: "starts with hyphen"),
            ManifestNameTestCase(name: "testImage", isValid: false, description: "contains uppercase"),
            ManifestNameTestCase(name: "test_image", isValid: false, description: "contains underscore"),
            ManifestNameTestCase(name: "test.image", isValid: false, description: "contains dot"),
            ManifestNameTestCase(name: "test image", isValid: false, description: "contains space"),
            ManifestNameTestCase(name: "a" + String(repeating: "b", count: 250), isValid: false, description: "too long (251 chars)"),
        ]
        
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        for testCase in testCases {
            let manifest = OriginalManifest(
                id: testCase.name,
                localID: "local_ID/\(testCase.name)",
                sha256: "hash",
                path: "/test/image.jpg",
                filesize: 1000,
                name: testCase.name,
                deviceSpace: "test-device",
                mediaType: "photo",
                width: 100,
                height: 100,
                modifiedAt: nil,
                duration: nil,
                mimeType: nil,
                location: nil,
                isFavorite: false,
                isHidden: false,
                burstIdentifier: nil
            )
            
            if testCase.isValid {
                try await service.createCommit(message: "Test: \(testCase.description)", items: [.manifest(manifest)])
            } else {
                await #expect(throws: InvalidManifestNameError.self) {
                    try await service.createCommit(message: "Test: \(testCase.description)", items: [.manifest(manifest)])
                }
            }
        }
    }
    
    @Test func testInvalidManifestNameForLFS() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let manifest = OriginalManifest(
            id: "InvalidLFS",
            localID: "local_ID/InvalidLFS",
            sha256: "hash",
            path: "/test/image.jpg",
            filesize: 1000,
            name: "InvalidLFS",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let pointer = encryptedPointer(oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", size: 1000)
        
        await #expect(throws: InvalidManifestNameError.self) {
            try await service.createCommit(message: "Test LFS validation", items: [.lfs(forManifest: manifest, pointer: pointer)])
        }
    }
    
    @Test func testInvalidManifestNameInMultipleItems() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let lfs = GitLFS(serverURL: "http://test.com")
        let service = DefaultGitCommitService(repository: repo, deviceSpace: "test-device", lfsClient: lfs)
        
        let validManifest = OriginalManifest(
            id: "valid-name",
            localID: "local_ID/valid-name",
            sha256: "hash1",
            path: "/test/1.jpg",
            filesize: 1000,
            name: "valid-name",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        let invalidManifest = OriginalManifest(
            id: "InvalidName",
            localID: "local_ID/InvalidName",
            sha256: "hash2",
            path: "/test/2.jpg",
            filesize: 2000,
            name: "InvalidName",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )
        
        await #expect(throws: InvalidManifestNameError.self) {
            try await service.createCommit(
                message: "Test multiple items",
                items: [.manifest(validManifest), .manifest(invalidManifest)]
            )
        }
    }
}

