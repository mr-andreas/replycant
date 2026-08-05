import Foundation
import Testing
import LibGit2

// Verifies no-op push/pull paths stay quiet at INFO level so periodic sync
// logs only signal actual state changes or failures.
@Suite("Git No-Op Sync Log Tests", .serialized)
struct GitNoOpSyncLogTests {
    // Asserts a no-op operation stayed quiet at the routine levels. Warnings
    // and errors are left alone so a genuine failure surfaces as itself rather
    // than as a log-noise regression.
    private func expectNoRoutineLogs(
        _ lines: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let routine = lines.filter {
            $0.contains("[INFO][Git]") || $0.contains("[DEBUG][Git]")
        }
        #expect(
            routine.isEmpty,
            Comment(rawValue: "unexpected routine log output: \(routine)"),
            sourceLocation: sourceLocation
        )
    }

    // Builds a local branch state where push exits early because origin/main
    // already points at the local HEAD commit.
    private func setupPushNoOpRepository() throws -> (repo: Repository, rootPath: String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("push-noop-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let repo = try Repository.create(at: root, bare: false)
        try repo.createCommit(
            message: "seed",
            files: [(path: "seed.txt", content: "seed")]
        )
        try repo.addRemote(name: "origin", url: "mtls+https://invalid.example/repo.git")

        let branchName = try #require(repo.currentBranch())
        let headOid = try #require(repo.headOID())
        try repo.updateRemoteRef(remoteName: "origin", branchName: branchName, oid: headOid)
        return (repo, root)
    }

    // Builds a local/remote topology where pull-rebase fetches but finds no
    // divergence, so the operation is a no-op.
    private func setupPullNoOpRepository() throws -> (repo: Repository, rootPath: String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pull-noop-logs-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let localPath = (root as NSString).appendingPathComponent("local")
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
        return (local, root)
    }

    // Ensures no-op push produces no visible log output at the default INFO level.
    @Test func pushNoOpEmitsNoInfoGitLogs() throws {
        let (repo, rootPath) = try setupPushNoOpRepository()
        defer { try? FileManager.default.removeItem(atPath: rootPath) }

        let (_, lines) = try withGitLogCapture {
            try repo.push(remoteName: "origin", branchName: "main")
        }

        expectNoRoutineLogs(lines)
    }

    // Ensures no-op pull-rebase produces no visible log output at the default INFO level.
    @Test func pullRebaseNoOpEmitsNoInfoGitLogs() throws {
        let (repo, rootPath) = try setupPullNoOpRepository()
        defer { try? FileManager.default.removeItem(atPath: rootPath) }

        let (_, lines) = try withGitLogCapture {
            try repo.pullRebase(remoteName: "origin", branchName: "main")
        }

        expectNoRoutineLogs(lines)
    }
}
