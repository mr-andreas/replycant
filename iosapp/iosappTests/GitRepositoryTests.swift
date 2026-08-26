import Foundation
import Testing
@testable import iosapp
import LibGit2

// Tests that demonstrate using the test fixtures with git repository and LFS
@MainActor
struct GitRepositoryTests {
    // Captures lock timeline events so serialization assertions do not rely on wall-clock timing.
    private actor MutationLockTimeline {
        private var events: [String] = []

        // Records one timeline marker from a mutation closure.
        func append(_ event: String) {
            events.append(event)
        }

        // Returns captured markers in write order.
        func snapshot() -> [String] {
            events
        }
    }

    // Shards expected fixture names so repository assertions match production manifest and pointer layout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }
    
    @Test func testRepositorySetup() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        // Verify repository exists
        let repo = try Repository(path: repoPath)
        #expect(repo.path != nil)
        #expect(repo.workdir != nil)
        
        // Verify we have a working directory
        let workdir = try #require(repo.workdir)
        #expect(FileManager.default.fileExists(atPath: workdir))
    }
    
    @Test func testManifestFilesExist() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        // Check that manifest files were committed
        let manifestPath = "manifests/test-device-space/media.replycant.com/v1alpha1/Original/\(shardName("i-1")).yaml"
        #expect(repo.fileExists(at: manifestPath))
        
        // Verify manifest is stored encrypted at rest.
        let content = try repo.readFile(at: manifestPath)
        #expect(content.contains("REPLYCANT-ENC-V1"))
        #expect(content.contains("kek-epoch:"))
    }
    
    @Test func testLFSPointerFilesExist() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        // Check that LFS pointer files were committed
        let pointerPath = "binary/test-device-space/media.replycant.com/v1alpha1/Original/\(shardName("i-1"))"
        #expect(repo.fileExists(at: pointerPath))
        
        // Verify pointer content
        let content = try repo.readFile(at: pointerPath)
        #expect(content.contains("version https://git-lfs.github.com/spec/v1"))
        #expect(content.contains("oid sha256:"))
        #expect(content.contains("size "))
    }
    
    @Test func testThumbnailManifestsExist() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        let manifestPath = "manifests/test-device-space/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName("i-1-thumbs")).yaml"
        #expect(repo.fileExists(at: manifestPath))
        let content = try repo.readFile(at: manifestPath)
        #expect(content.contains("REPLYCANT-ENC-V1"))
        #expect(content.contains("kek-epoch:"))
    }
    
    @Test func testLFSServerHasData() async throws {
        let fixtures = TestFixtures()
        let (repoPath, lfsServer) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        // Verify LFS server has stored data
        let oids = lfsServer.allOIDs()
        print("LFS Server has \(oids.count) OIDs: \(oids)")
        #expect(oids.count > 0)
        
        // Should have data for originals and thumbnails
        // 3 photos * (1 original + 3 thumbnails) = 12 objects
        // Note: some OIDs may be duplicated if data is identical
        #expect(oids.count >= 3, "Expected at least 3 unique OIDs (one per photo)")
    }
    
    @Test func testLFSServerBatchUpload() async throws {
        let fixtures = TestFixtures()
        let (repoPath, lfsServer) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        // Test batch upload request for new object
        let testData = Data("Test data for upload".utf8)
        let testOid = MockLFSServer.calculateSHA256(data: testData)
        
        let response = lfsServer.handleBatchUploadRequest(objects: [(oid: testOid, size: Int64(testData.count))])
        
        #expect(response.objects.count == 1)
        let obj = try #require(response.objects.first)
        #expect(obj.oid == testOid)
        #expect(obj.actions?.upload != nil)
        
        // Actually upload the data
        let uploadSuccess = lfsServer.handleUpload(oid: testOid, data: testData)
        #expect(uploadSuccess)
        
        // Verify data is stored
        #expect(lfsServer.exists(oid: testOid))
    }
    
    @Test func testLFSServerBatchDownload() async throws {
        let fixtures = TestFixtures()
        let (repoPath, lfsServer) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        // Store test data
        let testData = Data("Test data for download".utf8)
        let (oid, size) = lfsServer.uploadData(testData)
        
        // Test batch download request
        let response = lfsServer.handleBatchDownloadRequest(objects: [(oid: oid, size: size)])
        
        #expect(response.objects.count == 1)
        let obj = try #require(response.objects.first)
        #expect(obj.oid == oid)
        #expect(obj.actions?.download != nil)
        #expect(obj.error == nil)
        
        // Actually download the data
        let downloadedData = lfsServer.handleDownload(oid: oid)
        #expect(downloadedData == testData)
    }
    
    @Test func testLFSServerMissingObject() async throws {
        let fixtures = TestFixtures()
        let (repoPath, lfsServer) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        // Request non-existent object
        let fakeOid = "0000000000000000000000000000000000000000000000000000000000000000"
        let response = lfsServer.handleBatchDownloadRequest(objects: [(oid: fakeOid, size: 100)])
        
        #expect(response.objects.count == 1)
        let obj = try #require(response.objects.first)
        #expect(obj.error != nil)
        #expect(obj.error?.code == 404)
    }
    
    @Test func testMultiplePhotosInRepository() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        // Check all three test photos exist
        let photoNames = ["i-1", "i-2", "i-3"]
        for photoName in photoNames {
            let manifestPath = "manifests/test-device-space/media.replycant.com/v1alpha1/Original/\(shardName(photoName)).yaml"
            #expect(repo.fileExists(at: manifestPath))
        }
    }
    
    @Test func testRepositoryHasCommit() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }
        
        let repo = try Repository(path: repoPath)
        
        // Check that repository has a commit
        let status = repo.getStatus()
        #expect(status.contains("branch") || status.contains("Working tree clean"))
    }

    // Verifies origin can be repointed so the app can switch servers without recreating the local repo.
    @Test func testOriginURLCanBeUpdated() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }

        let repo = try Repository(path: repoPath)

        try repo.addRemote(name: "origin", url: "https://example.com/one.git")
        #expect(repo.getRemoteUrl() == "https://example.com/one.git")

        try repo.addRemote(name: "origin", url: "https://example.com/two.git")
        #expect(repo.getRemoteUrl() == "https://example.com/two.git")
    }
    
    // Verifies custom URL schemes are accepted without validation errors.
    @Test func testCustomURLSchemesAccepted() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }

        let repo = try Repository(path: repoPath)

        // Custom schemes like mtld+https should be accepted
        try repo.addRemote(name: "origin", url: "mtld+https://replycant.local:8443/")
        #expect(repo.getRemoteUrl() == "mtld+https://replycant.local:8443/")
        
        // Can also use other custom schemes
        try repo.addRemote(name: "origin", url: "custom-scheme://server.local/path")
        #expect(repo.getRemoteUrl() == "custom-scheme://server.local/path")
    }

    // Verifies push becomes a no-op when local HEAD already matches origin tracking ref.
    @Test func testPushNoOpWhenHeadMatchesRemoteTrackingRef() async throws {
        let fixtures = TestFixtures()
        let (repoPath, _) = try fixtures.setupTestRepository()
        defer { fixtures.cleanupTestRepository(at: repoPath) }

        let repo = try Repository(path: repoPath)
        try repo.addRemote(name: "origin", url: "mtls+https://invalid.example/repo.git")

        let branchName = try #require(repo.currentBranch())
        let headOid = try #require(repo.headOID())
        try repo.updateRemoteRef(remoteName: "origin", branchName: branchName, oid: headOid)

        try repo.push(remoteName: "origin", branchName: branchName)
    }
    // Verifies pullRebase returns without history rewrite when local HEAD already matches origin.
    @Test func testPullRebaseNoOpWhenHeadMatchesOrigin() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-noop-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let localPath = (root as NSString).appendingPathComponent("local")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let local = try Repository.clone(from: remotePath, to: localPath)
        let headBeforePull = try #require(local.headOID())

        try local.pullRebase(remoteName: "origin", branchName: "main")

        #expect(local.headOID() == headBeforePull)
    }
    
    // Verifies pullRebase updates local branch tip after 0-op in-memory rebase so follow-up push is a no-op.
    @Test func testPullRebaseFastForwardUpdatesHeadThenPushNoOp() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-ff-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let writerPath = (root as NSString).appendingPathComponent("writer")
        let localPath = (root as NSString).appendingPathComponent("local")
        defer { try? FileManager.default.removeItem(atPath: root) }
        
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)
        
        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")
        
        let local = try Repository.clone(from: remotePath, to: localPath)
        let writer = try Repository.clone(from: remotePath, to: writerPath)
        
        try writer.createCommit(
            message: "advance remote",
            files: [(path: "remote.txt", content: "remote-advance")]
        )
        let remoteHeadAfterAdvance = try #require(writer.headOID())
        try writer.push(remoteName: "origin", branchName: "main")
        
        #expect(local.headOID() != remoteHeadAfterAdvance)
        
        try local.pullRebase(remoteName: "origin", branchName: "main")
        #expect(local.headOID() == remoteHeadAfterAdvance)
        
        try local.push(remoteName: "origin", branchName: "main")
    }

    // Verifies pullRebase keeps local commits by rebasing when local and remote both advanced.
    @Test func testPullRebaseRebasesWhenLocalAndRemoteDiverge() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-diverge-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let writerPath = (root as NSString).appendingPathComponent("writer")
        let localPath = (root as NSString).appendingPathComponent("local")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let local = try Repository.clone(from: remotePath, to: localPath)
        let writer = try Repository.clone(from: remotePath, to: writerPath)

        try local.createCommit(
            message: "local change",
            files: [(path: "local.txt", content: "local")]
        )
        let localHeadBeforePull = try #require(local.headOID())

        try writer.createCommit(
            message: "remote change",
            files: [(path: "remote.txt", content: "remote")]
        )
        let remoteHeadAfterAdvance = try #require(writer.headOID())
        try writer.push(remoteName: "origin", branchName: "main")

        try local.pullRebase(remoteName: "origin", branchName: "main")
        let rebasedHead = try #require(local.headOID())

        #expect(rebasedHead != localHeadBeforePull)
        #expect(rebasedHead != remoteHeadAfterAdvance)

        #expect(local.fileExists(at: "local.txt"))
        #expect(local.fileExists(at: "remote.txt"))
    }

    // Verifies two clones that rebase the same local commit onto the same
    // upstream converge on one SHA so retries do not manufacture duplicates.
    @Test func testPullRebaseIsDeterministicAcrossClones() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-deterministic-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let sharedLocalPath = (root as NSString).appendingPathComponent("shared-local")
        let localAPath = (root as NSString).appendingPathComponent("local-a")
        let localBPath = (root as NSString).appendingPathComponent("local-b")
        let writerPath = (root as NSString).appendingPathComponent("writer")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let sharedLocal = try Repository.clone(from: remotePath, to: sharedLocalPath)
        try sharedLocal.createCommit(
            message: "local change",
            files: [(path: "local.txt", content: "local")]
        )

        let localA = try Repository.clone(from: sharedLocalPath, to: localAPath)
        let localB = try Repository.clone(from: sharedLocalPath, to: localBPath)
        try localA.addRemote(name: "origin", url: remotePath)
        try localB.addRemote(name: "origin", url: remotePath)

        let writer = try Repository.clone(from: remotePath, to: writerPath)
        try writer.createCommit(
            message: "remote change",
            files: [(path: "remote.txt", content: "remote")]
        )
        try writer.push(remoteName: "origin", branchName: "main")

        try localA.pullRebase(remoteName: "origin", branchName: "main")
        let headA = try #require(localA.headOID())

        try await Task.sleep(nanoseconds: 1_100_000_000)

        try localB.pullRebase(remoteName: "origin", branchName: "main")
        let headB = try #require(localB.headOID())

        #expect(headA == headB)
        #expect(localA.fileExists(at: "local.txt"))
        #expect(localA.fileExists(at: "remote.txt"))
        #expect(localB.fileExists(at: "local.txt"))
        #expect(localB.fileExists(at: "remote.txt"))
    }

    // Verifies pullRebase leaves HEAD unchanged when local is only ahead of
    // upstream, so a concurrent push cannot race a rewritten SHA.
    @Test func testPullRebaseNoOpWhenLocalIsAheadOfUpstream() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-ahead-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let localPath = (root as NSString).appendingPathComponent("local")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let local = try Repository.clone(from: remotePath, to: localPath)
        try local.createCommit(
            message: "local ahead",
            files: [(path: "local.txt", content: "ahead")]
        )
        let headBeforePull = try #require(local.headOID())

        try await Task.sleep(nanoseconds: 1_100_000_000)

        try local.pullRebase(remoteName: "origin", branchName: "main")
        #expect(local.headOID() == headBeforePull)
        #expect(local.fileExists(at: "local.txt"))
    }

    // Verifies pullRebase skips an already-applied local duplicate so a
    // device that rewrote a pushed commit can fast-forward back to origin.
    @Test func testPullRebaseSkipsAlreadyAppliedDuplicateCommit() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-rebase-eapplied-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let writerPath = (root as NSString).appendingPathComponent("writer")
        let localPath = (root as NSString).appendingPathComponent("local")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [
                (path: "keep.txt", content: "keep"),
                (path: "pubkeys/recovery.recovery.pub", content: "ssh"),
                (path: "pubkeys/recovery.recovery.age", content: "age"),
            ]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let local = try Repository.clone(from: remotePath, to: localPath)
        let writer = try Repository.clone(from: remotePath, to: writerPath)

        try writer.createCommit(
            message: "Remove recovery key remote",
            files: [],
            deletions: [
                "pubkeys/recovery.recovery.pub",
                "pubkeys/recovery.recovery.age",
            ]
        )
        let remoteHead = try #require(writer.headOID())
        try writer.push(remoteName: "origin", branchName: "main")

        try local.createCommit(
            message: "Remove recovery key local",
            files: [],
            deletions: [
                "pubkeys/recovery.recovery.pub",
                "pubkeys/recovery.recovery.age",
            ]
        )
        #expect(local.headOID() != remoteHead)

        try local.pullRebase(remoteName: "origin", branchName: "main")
        #expect(local.headOID() == remoteHead)
        #expect(local.fileExists(at: "keep.txt"))
        #expect(!local.fileExists(at: "pubkeys/recovery.recovery.pub"))

        try local.push(remoteName: "origin", branchName: "main")
    }

    // Verifies Git operation signposts do not change commit success behavior.
    @Test func testSignpostedCreateCommitStillSucceeds() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("signpost-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let repo = try Repository.create(at: root, bare: false)
        try repo.createCommit(
            message: "signpost smoke test",
            files: [(path: "signpost.txt", content: "ok")]
        )

        #expect(repo.headOID() != nil)
        #expect(repo.fileExists(at: "signpost.txt"))
    }

    // Verifies commit-time deletions remove tracked files so recovery-key replacement can revoke old pubkeys.
    @Test func testCreateCommitSupportsDeletions() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("delete-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let repo = try Repository.create(at: root, bare: false)
        try repo.createCommit(
            message: "seed files",
            files: [
                (path: "pubkeys/recovery-old.recovery.pub", content: "ssh-pub"),
                (path: "pubkeys/recovery-old.recovery.age", content: "age-pub"),
                (path: "pubkeys/keep.pub", content: "keep"),
            ]
        )
        #expect(repo.fileExists(at: "pubkeys/recovery-old.recovery.pub"))
        #expect(repo.fileExists(at: "pubkeys/recovery-old.recovery.age"))

        try repo.createCommit(
            message: "delete old recovery key",
            files: [],
            deletions: [
                "pubkeys/recovery-old.recovery.pub",
                "pubkeys/recovery-old.recovery.age",
            ]
        )

        #expect(!repo.fileExists(at: "pubkeys/recovery-old.recovery.pub"))
        #expect(!repo.fileExists(at: "pubkeys/recovery-old.recovery.age"))
        #expect(repo.fileExists(at: "pubkeys/keep.pub"))
    }

    // Verifies repository mutation lock strictly serializes overlapping mutation closures.
    @Test func testRepositoryMutationLockSerializesConcurrentMutations() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("repo-mutation-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let repository = try Repository.create(at: root, bare: false)
        let timeline = MutationLockTimeline()

        let firstTask = Task {
            try await repository.withMutationLock {
                await timeline.append("first-start")
                try await Task.sleep(nanoseconds: 150_000_000)
                await timeline.append("first-end")
            }
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        let secondTask = Task {
            try await repository.withMutationLock {
                await timeline.append("second-start")
                await timeline.append("second-end")
            }
        }

        try await firstTask.value
        try await secondTask.value

        let events = await timeline.snapshot()
        #expect(events == ["first-start", "first-end", "second-start", "second-end"])
    }
}

