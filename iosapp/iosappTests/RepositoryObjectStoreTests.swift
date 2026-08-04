import Foundation
import Testing
import LibGit2

@MainActor
struct RepositoryObjectStoreTests {
    // Shards fixture filenames to mirror production manifest and binary fanout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }

    @Test func testReadAndListFilesFromGitObjects() throws {
        let repoPath = makeTempDirectory(prefix: "object-read")
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let originalA = "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("a")).yaml"
        let originalB = "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("b")).yaml"
        try repository.createCommit(message: "seed", files: [
            (path: originalA, content: "kind: Original\n"),
            (path: originalB, content: "kind: Original\n")
        ])

        let files = try repository.listFiles(in: "manifests/device/media.replycant.com/v1alpha1/Original").sorted()
        #expect(files == [
            originalA,
            originalB
        ])

        let content = try repository.readFile(at: originalA)
        #expect(content == "kind: Original\n")
    }

    @Test func testCreateCommitDoesNotMaterializeWorkingTreeFiles() throws {
        let repoPath = makeTempDirectory(prefix: "in-memory-commit")
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let pointerPath = "binary/device/media.replycant.com/v1alpha1/Original/\(shardName("item"))"
        try repository.createCommit(message: "seed", files: [
            (path: pointerPath, content: "pointer-content")
        ])

        #expect(repository.fileExists(at: pointerPath))

        let workdir = try #require(repository.workdir)
        let materializedPath = (workdir as NSString).appendingPathComponent(pointerPath)
        #expect(FileManager.default.fileExists(atPath: materializedPath) == false)
    }

    @Test func testCloneWithCheckoutNoneKeepsObjectsReadable() throws {
        let sourcePath = makeTempDirectory(prefix: "clone-source")
        let clonePath = makeTempDirectory(prefix: "clone-dest")
        defer {
            try? FileManager.default.removeItem(atPath: sourcePath)
            try? FileManager.default.removeItem(atPath: clonePath)
        }

        try Git.initialize()
        let source = try Repository.create(at: sourcePath, bare: false)
        try source.createCommit(message: "seed", files: [
            (path: "encryption/current", content: "1\n")
        ])

        let clone = try Repository.clone(from: sourcePath, to: clonePath)
        #expect(clone.fileExists(at: "encryption/current"))
        #expect(try clone.readFile(at: "encryption/current") == "1\n")

        let workdir = try #require(clone.workdir)
        let checkedOutPath = (workdir as NSString).appendingPathComponent("encryption/current")
        #expect(FileManager.default.fileExists(atPath: checkedOutPath) == false)
    }

    @Test func testSequentialCommitsPreserveExistingFiles() throws {
        let repoPath = makeTempDirectory(prefix: "sequential-commits")
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)

        try repository.createCommit(message: "first", files: [
            (path: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("first")).yaml", content: "v: 1\n")
        ])
        try repository.createCommit(message: "second", files: [
            (path: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("second")).yaml", content: "v: 2\n")
        ])

        #expect(repository.fileExists(at: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("first")).yaml"))
        #expect(repository.fileExists(at: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("second")).yaml"))
        #expect(try repository.readFile(at: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName("first")).yaml") == "v: 1\n")
    }

    @Test func testListFilesReturnsAllEntriesFromDirectoryTree() throws {
        let repoPath = makeTempDirectory(prefix: "large-list")
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)

        var files: [(path: String, content: String)] = []
        files.reserveCapacity(250)
        for index in 0..<250 {
            files.append((
                path: "manifests/device/media.replycant.com/v1alpha1/Original/\(shardName(String(index))).yaml",
                content: "n: \(index)\n"
            ))
        }
        try repository.createCommit(message: "seed-many", files: files)

        let listed = try repository.listFiles(in: "manifests/device/media.replycant.com/v1alpha1/Original")
        #expect(listed.count == 250)
    }

    private func makeTempDirectory(prefix: String) -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
