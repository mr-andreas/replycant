import XCTest
import Foundation
import LibGit2
import GitDB
@testable import iosapp

// Benchmarks manifest crypto throughput through production git manifest entrypoints used by commit and load flows.
@MainActor
final class ManifestCryptoPerformanceTests: XCTestCase {
    // Creates the app registry shape used by manager queries.
    private func makeRegistry() -> ManifestRegistry {
        let registry = ManifestRegistry()
        registry.register(OriginalManifest.self) { reg in
            reg.column("takenAt", type: .real, nullable: true)
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("mediaType", type: .text)
            reg.column("sha256", type: .text)
            reg.column("isFavorite", type: .integer)
            reg.column("isHidden", type: .integer)
            reg.index(on: ["takenAt", "id"], where: "takenAt IS NOT NULL")
            reg.index(on: ["mediaType"])
            reg.index(on: ["sha256"])
            reg.extractColumns { manifest in
                [
                    "takenAt": manifest.spec.takenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "mediaType": .string(manifest.spec.mediaType),
                    "sha256": .string(manifest.spec.sha256),
                    "isFavorite": .int(manifest.spec.isFavorite ? 1 : 0),
                    "isHidden": .int(manifest.spec.isHidden ? 1 : 0),
                ]
            }
        }
        return registry
    }

    // Keeps benchmark settings configurable so local and CI machines can tune runtime without code edits.
    private struct BenchmarkConfig {
        let iterations: Int
        let manifestCount: Int
    }

    // Stores per-iteration timing and throughput so test output can report stable summary stats.
    private struct ThroughputSample {
        let durationSeconds: Double
        let manifestsPerSecond: Double
    }

    // Measures manifest encryption throughput via DefaultGitCommitService.createCommit used by git writes.
    func testManifestEncryptionThroughput() async throws {
        let config = benchmarkConfig()
        let setup = try await createEncryptedBenchmarkSetup()
        defer { try? FileManager.default.removeItem(atPath: setup.repoPath) }

        var samples: [ThroughputSample] = []
        for iteration in 0..<config.iterations {
            let items = buildManifestItems(iteration: iteration, manifestCount: config.manifestCount)
            let started = CFAbsoluteTimeGetCurrent()
            try await setup.commitService.createCommit(message: "bench-encrypt-\(iteration)", items: items)
            let durationSeconds = CFAbsoluteTimeGetCurrent() - started
            let throughput = Double(config.manifestCount) / max(durationSeconds, 0.000_001)
            samples.append(ThroughputSample(durationSeconds: durationSeconds, manifestsPerSecond: throughput))
        }

        let summary = summarize(samples: samples)
        print(
            "[manifest-crypto-bench][ios][encrypt] iterations=\(config.iterations) " +
            "manifestsPerIteration=\(config.manifestCount) " +
            String(format: "meanThroughput=%.2f manifests/s medianThroughput=%.2f manifests/s meanDuration=%.4fs", summary.meanThroughput, summary.medianThroughput, summary.meanDuration)
        )
        XCTAssertGreaterThan(summary.meanThroughput, 0)
    }

    // Measures manifest decryption throughput via database-backed manifest reads after sync.
    func testManifestDecryptionThroughput() async throws {
        let config = benchmarkConfig()
        let setup = try await createEncryptedBenchmarkSetup()
        defer { try? FileManager.default.removeItem(atPath: setup.repoPath) }

        let seedItems = buildManifestItems(iteration: 999, manifestCount: config.manifestCount)
        try await setup.commitService.createCommit(message: "bench-decrypt-seed", items: seedItems)
        try await setup.manager.syncToHead(progressHandler: nil)

        var samples: [ThroughputSample] = []
        for _ in 0..<config.iterations {
            let started = CFAbsoluteTimeGetCurrent()
            let manifests: [OriginalManifest] = try await setup.manager.loadAllManifests(deviceSpace: setup.deviceSpace)
            let durationSeconds = CFAbsoluteTimeGetCurrent() - started
            XCTAssertGreaterThanOrEqual(manifests.count, config.manifestCount)
            let throughput = Double(manifests.count) / max(durationSeconds, 0.000_001)
            samples.append(ThroughputSample(durationSeconds: durationSeconds, manifestsPerSecond: throughput))
        }

        let summary = summarize(samples: samples)
        print(
            "[manifest-crypto-bench][ios][decrypt] iterations=\(config.iterations) " +
            "manifestsPerIteration=\(config.manifestCount) " +
            String(format: "meanThroughput=%.2f manifests/s medianThroughput=%.2f manifests/s meanDuration=%.4fs", summary.meanThroughput, summary.medianThroughput, summary.meanDuration)
        )
        XCTAssertGreaterThan(summary.meanThroughput, 0)
    }

    // Builds a repository with active KEK epoch metadata so benchmark paths run with real manifest-at-rest encryption enabled.
    private func createEncryptedBenchmarkSetup() async throws -> (repoPath: String, deviceSpace: String, commitService: DefaultGitCommitService, manager: DefaultManifestManager) {
        let tempDir = NSTemporaryDirectory()
        let repoPath = (tempDir as NSString).appendingPathComponent("manifest-crypto-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "ManifestCryptoPerformanceTests")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()

        let kekManager = KEKEpochManager(repository: repository)
        let bootstrapFiles = try kekManager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        try repository.createCommit(message: "bootstrap encryption", files: bootstrapFiles)

        let deviceSpace = "bench-device"
        let commitService = DefaultGitCommitService(
            repository: repository,
            deviceSpace: deviceSpace,
            lfsClient: GitLFS(serverURL: "http://localhost")
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-crypto-bench-db-\(UUID().uuidString).sqlite")
        let registry = makeRegistry()
        let database = try ManifestDatabase(databaseURL: databaseURL, registry: registry)
        let manager = DefaultManifestManager(
            repository: repository,
            deviceSpace: deviceSpace,
            lfsClient: GitLFS(serverURL: "http://localhost"),
            database: database,
            registry: registry
        )
        try await manager.syncToHead(progressHandler: nil)
        return (repoPath, deviceSpace, commitService, manager)
    }

    // Produces benchmark manifest batches with valid IDs so commit path encryption is exercised repeatedly without validation failures.
    private func buildManifestItems(iteration: Int, manifestCount: Int) -> [GitCommitItem] {
        (0..<manifestCount).map { index in
            let id = "bench-\(iteration)-\(index)"
            let capturedAt = Date(timeIntervalSince1970: Double(iteration * 1_000 + index))
            return .manifest(
                OriginalManifest(
                    id: id,
                    localID: "local_ID/\(id)",
                    sha256: String(repeating: "a", count: 64),
                    path: "/bench/\(id).HEIC",
                    filesize: 2_000_000,
                    name: id,
                    deviceSpace: "bench-device",
                    mediaType: "photo",
                    width: 4032,
                    height: 3024,
                    modifiedAt: nil,
                    duration: nil,
                    mimeType: "image/heic",
                    location: nil,
                    isFavorite: false,
                    isHidden: false,
                    burstIdentifier: nil,
                    takenAt: capturedAt,
                    guessedTakenAt: capturedAt
                )
            )
        }
    }

    // Reads benchmark tuning from environment so throughput runs can scale by machine without source changes.
    private func benchmarkConfig() -> BenchmarkConfig {
        let env = ProcessInfo.processInfo.environment
        let iterations = max(1, Int(env["IOS_MANIFEST_BENCH_ITERATIONS"] ?? "") ?? 5)
        let manifestCount = max(1, Int(env["IOS_MANIFEST_BENCH_MANIFEST_COUNT"] ?? "") ?? 200)
        return BenchmarkConfig(iterations: iterations, manifestCount: manifestCount)
    }

    // Aggregates throughput samples so output highlights central tendency instead of single noisy iterations.
    private func summarize(samples: [ThroughputSample]) -> (meanThroughput: Double, medianThroughput: Double, meanDuration: Double) {
        guard !samples.isEmpty else {
            return (0, 0, 0)
        }
        let throughputs = samples.map(\.manifestsPerSecond).sorted()
        let durations = samples.map(\.durationSeconds)
        let meanThroughput = throughputs.reduce(0, +) / Double(throughputs.count)
        let meanDuration = durations.reduce(0, +) / Double(durations.count)
        let medianIndex = throughputs.count / 2
        let medianThroughput: Double
        if throughputs.count.isMultiple(of: 2) {
            medianThroughput = (throughputs[medianIndex - 1] + throughputs[medianIndex]) / 2
        } else {
            medianThroughput = throughputs[medianIndex]
        }
        return (meanThroughput, medianThroughput, meanDuration)
    }
}
