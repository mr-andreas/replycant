import Foundation
import Testing
import LibGit2

// Verifies no-op push/pull paths stay quiet at INFO level so periodic sync
// logs only signal actual state changes or failures.
@Suite("Git No-Op Sync Log Tests", .serialized)
struct GitNoOpSyncLogTests {
    // Captures stdout for one async block so tests can assert exact log levels.
    private func captureStdout(
        during work: () async throws -> Void
    ) async throws -> String {
        let pipe = Pipe()
        let originalFd = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await work()
        } catch {
            fflush(stdout)
            dup2(originalFd, STDOUT_FILENO)
            close(originalFd)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        fflush(stdout)
        dup2(originalFd, STDOUT_FILENO)
        close(originalFd)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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

    // Keeps only log lines naming this test's own repository.
    //
    // Redirecting STDOUT_FILENO captures the whole process, and suites that run
    // in parallel log while the capture is installed, so an unrelated test
    // creating a repository would otherwise be read as this push having logged.
    private func linesAboutRepository(at rootPath: String, in output: String) -> [String] {
        output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(rootPath) }
    }

    // Ensures no-op push produces no visible log output at the default INFO level.
    @Test func pushNoOpEmitsNoInfoGitLogs() async throws {
        let (repo, rootPath) = try setupPushNoOpRepository()
        defer { try? FileManager.default.removeItem(atPath: rootPath) }

        let output = try await captureStdout {
            try repo.push(remoteName: "origin", branchName: "main")
        }

        let ownLines = linesAboutRepository(at: rootPath, in: output)
        #expect(!ownLines.contains { $0.contains("[INFO][Git]") })
        #expect(!ownLines.contains { $0.contains("[DEBUG][Git]") })
    }

    // Ensures no-op pull-rebase produces no visible log output at the default INFO level.
    @Test func pullRebaseNoOpEmitsNoInfoGitLogs() async throws {
        let (repo, rootPath) = try setupPullNoOpRepository()
        defer { try? FileManager.default.removeItem(atPath: rootPath) }

        let output = try await captureStdout {
            try repo.pullRebase(remoteName: "origin", branchName: "main")
        }

        let ownLines = linesAboutRepository(at: rootPath, in: output)
        #expect(!ownLines.contains { $0.contains("[INFO][Git]") })
        #expect(!ownLines.contains { $0.contains("[DEBUG][Git]") })
    }
}
