import Foundation
import LibGit2
import Yams

// Encapsulates git commit creation to decouple managers from direct repository access.
// Works with any Manifest type and LFS pointers, deriving file paths from manifest metadata.
public protocol GitCommitService {
    // Creates a commit with manifests encrypted at rest while preserving existing manifest/LFS path conventions.
    func createCommit(message: String, items: [GitCommitItem]) async throws
    
    // Uploads data to LFS and writes pointer file, enabling test mocking without direct Repository access.
    // Derives the LFS path from manifest metadata to maintain consistency with createCommit path logic.
    @available(iOS 13.0, macOS 10.15, *)
    // Uploads binary data to LFS and returns pointer metadata that will be committed alongside manifests.
    func addLFSData(_ data: Data, for manifest: any Manifest, progressHandler: ((Int64, Int64) -> Void)?) async throws -> LFSPointer

    // Uploads one source file with on-the-fly encryption so large binaries can avoid full in-memory ciphertext staging.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        for manifest: any Manifest,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer

    // Uploads binary data to LFS using an explicit kind/name path for one manifest entry.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(
        _ data: Data,
        apiVersion: String,
        kind: String,
        name: String,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer

    // Cancels any active LFS transfer so user-requested upload cancellation halts network work immediately.
    func cancelActiveLFSUpload()
}

// Represents items to be committed: manifests (as YAML) or LFS pointers.
public enum GitCommitItem {
    case manifest(_ manifest: any Manifest)
    case lfs(forManifest: any Manifest, pointer: LFSPointer)
    case lfsEntry(apiVersion: String, kind: String, name: String, pointer: LFSPointer)
}

// Error thrown when a manifest name violates ADR-0003 naming conventions.
public struct InvalidManifestNameError: Error {
    public let name: String
    public let reason: String
    
    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

// Signals strict encryption policy violations so commits cannot write plaintext repository content.
public enum GitCommitEncryptionError: Error {
    case missingActiveKEK
}

// Default implementation that writes manifests and LFS pointers to the git repository
// using paths derived from the manifest's metadata and the injected device space.
public final class DefaultGitCommitService: GitCommitService {
    private let repository: Repository
    private let deviceSpace: String
    private let lfsClient: GitLFS
    
    public init(repository: Repository, deviceSpace: String, lfsClient: GitLFS) {
        self.repository = repository
        self.deviceSpace = deviceSpace
        self.lfsClient = lfsClient
    }
    
    // Validates manifest name according to ADR-0003: must match [a-z][a-z0-9-]{0,249}
    // (starts with lowercase letter, contains only lowercase letters/digits/hyphens, 1-250 chars)
    // Max 250 chars ensures filename with .yaml extension (255 chars) fits filesystem limits.
    private func validateManifestName(_ name: String) throws {
        let pattern = "^[a-z][a-z0-9-]{0,249}$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw InvalidManifestNameError(name: name, reason: "Invalid validation pattern")
        }
        
        let range = NSRange(location: 0, length: name.utf16.count)
        guard regex.firstMatch(in: name, options: [], range: range) != nil else {
            throw InvalidManifestNameError(name: name, reason: "Name does not match ADR-0003 naming convention: [a-z][a-z0-9-]{0,249}")
        }
    }
    
    // Encrypts manifest YAML with the active KEK before writing files so repository history stores ciphertext only.
    public func createCommit(message: String, items: [GitCommitItem]) async throws {
        var files: [(String, String)] = []
        let activeKEK = try KEKEpochManager(repository: repository).loadCurrentKEK()
        
        for item in items {
            switch item {
            case .manifest(let manifest):
                try validateManifestName(manifest.id)
                let path = "manifests/\(deviceSpace)/\(manifest.apiVersionValue)/\(manifest.kindValue)/\(shardName(manifest.id)).yaml"
                let encoder = YAMLEncoder()
                let yaml = try encoder.encode(manifest)
                let encrypted = try EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: activeKEK.kek)
                let encodedPayload = encrypted.base64EncodedString()
                let encryptedManifest = """
                REPLYCANT-ENC-V1
                kek-epoch: \(activeKEK.epoch)
                ---
                \(encodedPayload)
                """
                files.append((path, encryptedManifest))
                
            case .lfs(let manifest, let pointer):
                try validateManifestName(manifest.id)
                let path = "binary/\(deviceSpace)/\(manifest.apiVersionValue)/\(manifest.kindValue)/\(shardName(manifest.id))"
                files.append((path, pointer.content))
            case .lfsEntry(let apiVersion, let kind, let name, let pointer):
                try validateManifestName(name)
                let path = "binary/\(deviceSpace)/\(apiVersion)/\(kind)/\(shardName(name))"
                files.append((path, pointer.content))
            }
        }
        
        try repository.createCommit(message: message, files: files)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSData(_ data: Data, for manifest: any Manifest, progressHandler: ((Int64, Int64) -> Void)?) async throws -> LFSPointer {
        let path = "binary/\(deviceSpace)/\(manifest.apiVersionValue)/\(manifest.kindValue)/\(shardName(manifest.id))"
        return try await repository.addLFSData(data, toPath: path, lfsClient: lfsClient, progressHandler: progressHandler)
    }

    // Uploads one manifest binary from disk while encrypting each chunk during transport to keep memory bounded for large media.
    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        for manifest: any Manifest,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        let path = "binary/\(deviceSpace)/\(manifest.apiVersionValue)/\(manifest.kindValue)/\(shardName(manifest.id))"
        return try await repository.addLFSFileEncrypting(
            at: fileURL,
            dek: dek,
            oid: oid,
            size: size,
            toPath: path,
            lfsClient: lfsClient,
            progressHandler: progressHandler
        )
    }

    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSData(
        _ data: Data,
        apiVersion: String,
        kind: String,
        name: String,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        try validateManifestName(name)
        let path = "binary/\(deviceSpace)/\(apiVersion)/\(kind)/\(shardName(name))"
        return try await repository.addLFSData(data, toPath: path, lfsClient: lfsClient, progressHandler: progressHandler)
    }

    // Routes cancellation to the shared LFS client so in-flight PUT requests are terminated.
    public func cancelActiveLFSUpload() {
        lfsClient.cancelActiveUpload()
    }
}

