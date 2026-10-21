import Foundation
import GitDB
import LibGit2
import Testing
@testable import iosapp

// Proves a manifest commit does not hold the main actor across the libgit2
// index write, and that one service reuses its KEK instead of decrypting it
// again for every photo.
@MainActor
@Suite("Git commit off the main actor", .serialized, .sharedAppState)
struct GitCommitOffMainActorTests {
    private func makeRepository() throws -> (path: String, repository: Repository) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("commit-off-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Git.initialize()
        let repository = try Repository.create(at: path, bare: false)
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "commit-off-main")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let bootstrap = try KEKEpochManager(repository: repository)
            .bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        try repository.createCommit(message: "Bootstrap encryption", files: bootstrap)
        return (path, repository)
    }

    private func makeManifest(id: String) -> OriginalManifest {
        OriginalManifest(
            id: id,
            localID: "local_ID/\(id)",
            sha256: "abc123",
            path: "/test/\(id).jpg",
            filesize: 128,
            name: id,
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )
    }

    @Test func createCommitYieldsTheMainActor() async throws {
        let (path, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let service = DefaultGitCommitService(
            repository: repository,
            deviceSpace: "test-device",
            lfsClient: GitLFS(serverURL: "http://test.com", router: .passthroughForTests())
        )
        var ran = false
        let marker = Task { @MainActor in
            ran = true
        }
        try await service.createCommit(
            message: "Add photo",
            items: [.manifest(makeManifest(id: "yield-photo"))]
        )
        #expect(ran)
        await marker.value
        #expect(repository.headOID() != nil)
    }

    @Test func createCommitDecryptsTheKEKOnce() async throws {
        let (path, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = IdentityLoadCounter()
        let service = DefaultGitCommitService(
            repository: repository,
            deviceSpace: "test-device",
            lfsClient: GitLFS(serverURL: "http://test.com", router: .passthroughForTests()),
            ageIdentityLoader: {
                counter.count += 1
                return try ClientIdentityManager.shared.agePrivateKey()
            }
        )
        try await service.createCommit(
            message: "Add first",
            items: [.manifest(makeManifest(id: "first-photo"))]
        )
        try await service.createCommit(
            message: "Add second",
            items: [.manifest(makeManifest(id: "second-photo"))]
        )
        #expect(counter.count == 1)
    }
}

// Counts age-identity loads so a second commit can show the KEK cache hit.
private final class IdentityLoadCounter: @unchecked Sendable {
    var count = 0
}
