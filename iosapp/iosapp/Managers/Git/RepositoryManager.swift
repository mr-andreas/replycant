import Foundation
import LibGit2

// Manages a shared instance of Repository for the entire app.
// Centralizes repository path logic and ensures a single Repository instance is reused,
// preventing redundant repository initialization across different parts of the app.
@MainActor
final class RepositoryManager {
    static let shared = RepositoryManager()
    
    private var cachedRepository: Repository?
    
    private init() {}
    
    // Returns the standard repository path used throughout the app.
    // This centralizes the path calculation to eliminate duplication.
    func repositoryPath() -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        return (documentsPath as NSString).appendingPathComponent("replycant-git-db")
    }
    
    // Gets or creates a repository instance for the standard repository path.
    // Validates that the repository exists before returning.
    // Throws an error if the repository does not exist at the expected path.
    func getRepository() throws -> Repository {
        if let existingRepository = cachedRepository {
            return existingRepository
        }
        
        let repoPath = repositoryPath()
        
        guard Repository.exists(at: repoPath) else {
            throw RepositoryError.notFound(path: repoPath)
        }
        
        let repository = try Repository(path: repoPath)
        self.cachedRepository = repository
        return repository
    }
    
    // Clears the cached repository instance.
    // Should be called when you need to force a fresh repository instance,
    // such as after major git operations that might invalidate the current state.
    func clearRepository() {
        cachedRepository = nil
    }

    // Supports reset-path tests by allowing cache priming without depending on the production repository location.
    func cacheRepositoryForTesting(_ repository: Repository) {
        cachedRepository = repository
    }

    // Exposes repository cache state for tests that must verify destructive resets clear in-memory git handles.
    var hasCachedRepositoryForTesting: Bool {
        cachedRepository != nil
    }
}

// Errors that can occur when working with the repository manager
enum RepositoryError: Error, LocalizedError {
    case notFound(path: String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Repository not found at: \(path)"
        }
    }
}
