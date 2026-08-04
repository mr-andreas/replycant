import Foundation

// Centralizes local-state wipes so reset flows can clear on-device git state without touching long-lived identities.
final class StateResetManager {
    static let shared = StateResetManager()

    private init() {}

    // Removes local repository state while preserving Keychain identity material and server configuration.
    func wipeLocalStateKeepingKeys(repositoryPath: String, onProgress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: repositoryPath) else {
                onProgress(1.0)
                return
            }

            let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            let topLevelEntries = try fileManager.contentsOfDirectory(at: repositoryURL, includingPropertiesForKeys: nil)
            let totalEntries = max(topLevelEntries.count, 1)

            for (index, entryURL) in topLevelEntries.enumerated() {
                try fileManager.removeItem(at: entryURL)
                let fraction = Double(index + 1) / Double(totalEntries)
                onProgress(fraction)
            }

            try fileManager.removeItem(at: repositoryURL)
            onProgress(1.0)
        }.value

        await RepositoryManager.shared.clearRepository()
        await GitDBManager.shared.clearGitDB()
        try await ManifestLoaderManager.shared.deleteDatabaseFile()
        await MainActor.run {
            UploadedMediaCache.shared.clear()
        }
    }
}
