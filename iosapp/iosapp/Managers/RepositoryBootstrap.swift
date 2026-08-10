import Foundation
import LibGit2

// Centralizes clone and hydration mechanics so onboarding, recovery, and resync stay behaviorally aligned.
enum RepositoryBootstrap {
    // Removes stale checkouts, clones with progress callbacks, and clears git/database caches for fresh reads.
    static func clone(
        serverURL: String,
        repositoryPath: String,
        progress: ((String, Double) -> Void)? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: repositoryPath) {
            try FileManager.default.removeItem(atPath: repositoryPath)
        }

        let mtlsURL = MTLSTransport.convertToMTLSScheme(serverURL)
        _ = try await Task.detached {
            try Repository.clone(from: mtlsURL, to: repositoryPath, depth: 1) { gitProgress in
                progress?("Cloning: \(gitProgress.description)", gitProgress.percentage)
            }
        }.value

        await MainActor.run {
            RepositoryManager.shared.clearRepository()
            GitDBManager.shared.clearGitDB()
        }
    }

    // Rebuilds the manifest index after clone so local SQL cache converges to repository HEAD.
    static func hydrateIndex(
        resetDatabase: Bool,
        progress: ((String, Double) -> Void)? = nil
    ) async throws {
        if resetDatabase {
            try await MainActor.run {
                try ManifestLoaderManager.shared.deleteDatabaseFile()
            }
        }

        let gitDB = try await MainActor.run {
            try GitDBManager.shared.getGitDB()
        }
        try await gitDB.syncToHead { phase, loaded, total in
            let fraction = total > 0 ? Double(loaded) / Double(total) : 0
            progress?("\(phase) (\(loaded)/\(total))", fraction * 100)
        }
    }

    // Maps phase-scoped progress into caller-defined ranges so each flow keeps intuitive step weighting.
    static func scaled(_ percent: Double, into range: ClosedRange<Double>) -> Double {
        let clamped = min(max(percent, 0), 100)
        let fraction = clamped / 100
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }
}
