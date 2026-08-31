import Foundation
import LibGit2

// Reports sync progress so UI callers can render hydration progress bars.
public typealias SyncProgressHandler = (_ phase: String, _ loaded: Int, _ total: Int) -> Void

// Coordinates commit-based diffing and database mutations so manifest reads never need direct git access.
public actor ManifestSyncEngine {
    // Carries old/new parsed states for one changed path so incremental sync can merge parallel results deterministically.
    private struct IncrementalManifestPair: Sendable {
        let oldManifest: (any Manifest)?
        let newManifest: (any Manifest)?
    }

    // Limits in-flight parse tasks so large syncs stream progress instead of queuing hundreds of thousands of tasks.
    private static let maxConcurrentParseTasks = max(4, min(ProcessInfo.processInfo.activeProcessorCount * 2, 24))

    private let repository: Repository
    private let database: ManifestDatabase
    private let registry: ManifestRegistry
    // Lets package tests inject a fixed KEK without Keychain-backed age identity.
    private let loadKEKForEpoch: (Int) throws -> Data

    // Binds one repository to one manifest cache database for deterministic sync operations.
    public init(repository: Repository, database: ManifestDatabase, registry: ManifestRegistry) {
        let kekEpochManager = KEKEpochManager(repository: repository)
        self.init(
            repository: repository,
            database: database,
            registry: registry,
            loadKEKForEpoch: { epoch in try kekEpochManager.loadKEK(epoch: epoch) }
        )
    }

    // Test seam that injects KEK loading so package tests can encrypt fixtures without Keychain.
    init(
        repository: Repository,
        database: ManifestDatabase,
        registry: ManifestRegistry,
        loadKEKForEpoch: @escaping (Int) throws -> Data
    ) {
        self.repository = repository
        self.database = database
        self.registry = registry
        self.loadKEKForEpoch = loadKEKForEpoch
    }

    // Synchronizes the database to HEAD using full hydration or incremental tree-diff updates.
    public func syncToHead(progressHandler: SyncProgressHandler? = nil) async throws {
        guard let head = repository.headOID() else {
            try await database.clearAll()
            return
        }
        let observed = try DatabaseVersion.read(in: repository, commitOid: head)
        try DatabaseVersion.requireAccepted(observed)
        let cacheFormat = try await database.readCacheFormatVersion()
        try DatabaseVersion.requireNoDowngrade(observed: observed, stored: cacheFormat)
        if cacheFormat != observed {
            try await performFullHydration(
                commitOid: head,
                progressHandler: progressHandler,
                cacheFormatVersion: observed
            )
            return
        }

        let previousSynced = try await database.readSyncedCommitHash()
        guard previousSynced != head else {
            return
        }

        guard let previousSynced else {
            try await performFullHydration(
                commitOid: head,
                progressHandler: progressHandler,
                cacheFormatVersion: observed
            )
            return
        }

        let changedPaths = try listChangedManifestPathsBetweenCommits(oldCommit: previousSynced, newCommit: head)
        if changedPaths.isEmpty {
            // Advances checkpoint only when manifest trees are identical (e.g. rebase rewrote commit IDs).
            try await database.writeSyncedCommitHashOnly(head)
            return
        }

        var added: [any Manifest] = []
        var updated: [any Manifest] = []
        var removed: [any Manifest] = []

        let keksByEpoch = try preloadAllKEKs()
        var remainingPaths = changedPaths[...]
        try await withThrowingTaskGroup(of: IncrementalManifestPair.self) { group in
            let initialTaskCount = min(Self.maxConcurrentParseTasks, remainingPaths.count)
            for _ in 0..<initialTaskCount {
                let path = remainingPaths.removeFirst()
                group.addTask { [self] in
                    let oldManifest: (any Manifest)?
                    if let oldBlob = try self.repository.readBlobDataAtCommit(commitOid: previousSynced, filepath: path) {
                        oldManifest = try Self.parseManifestBlob(oldBlob, path: path, keksByEpoch: keksByEpoch, registry: self.registry)
                    } else {
                        oldManifest = nil
                    }

                    let newManifest: (any Manifest)?
                    if let newBlob = try self.repository.readBlobDataAtCommit(commitOid: head, filepath: path) {
                        newManifest = try Self.parseManifestBlob(newBlob, path: path, keksByEpoch: keksByEpoch, registry: self.registry)
                    } else {
                        newManifest = nil
                    }
                    return IncrementalManifestPair(oldManifest: oldManifest, newManifest: newManifest)
                }
            }

            for try await pair in group {
                if !remainingPaths.isEmpty {
                    let path = remainingPaths.removeFirst()
                    group.addTask { [self] in
                        let oldManifest: (any Manifest)?
                        if let oldBlob = try self.repository.readBlobDataAtCommit(commitOid: previousSynced, filepath: path) {
                            oldManifest = try Self.parseManifestBlob(oldBlob, path: path, keksByEpoch: keksByEpoch, registry: self.registry)
                        } else {
                            oldManifest = nil
                        }

                        let newManifest: (any Manifest)?
                        if let newBlob = try self.repository.readBlobDataAtCommit(commitOid: head, filepath: path) {
                            newManifest = try Self.parseManifestBlob(newBlob, path: path, keksByEpoch: keksByEpoch, registry: self.registry)
                        } else {
                            newManifest = nil
                        }
                        return IncrementalManifestPair(oldManifest: oldManifest, newManifest: newManifest)
                    }
                }

                switch (pair.oldManifest, pair.newManifest) {
                case (nil, .some(let newManifest)):
                    added.append(newManifest)
                case (.some, .some(let newManifest)):
                    updated.append(newManifest)
                case (.some(let oldManifest), nil):
                    removed.append(oldManifest)
                case (nil, nil):
                    continue
                }
            }
        }

        try await database.applyMutation(
            added: added,
            updated: updated,
            removed: removed,
            commitHash: head,
            cacheFormatVersion: observed
        )
    }

    // Applies local commit manifests directly so write paths remain git-first and then cache-consistent.
    public func syncAfterCommit(items: [GitCommitItem]) async throws {
        guard let head = repository.headOID() else {
            return
        }
        let observed = try DatabaseVersion.read(in: repository, commitOid: head)
        try DatabaseVersion.requireAccepted(observed)
        let cacheFormat = try await database.readCacheFormatVersion()
        try DatabaseVersion.requireNoDowngrade(observed: observed, stored: cacheFormat)
        if cacheFormat != observed {
            try await performFullHydration(
                commitOid: head,
                progressHandler: nil,
                cacheFormatVersion: observed
            )
            return
        }

        var added: [any Manifest] = []
        var updated: [any Manifest] = []

        for item in items {
            guard case .manifest(let manifest) = item else {
                continue
            }
            if try await database.manifestExists(kind: manifest.kindValue, id: manifest.id) {
                updated.append(manifest)
            } else {
                added.append(manifest)
            }
        }

        try await database.applyMutation(
            added: added,
            updated: updated,
            removed: [],
            commitHash: head,
            cacheFormatVersion: observed
        )
    }

    // Performs first-time hydration by loading all manifests from one commit and replacing cache state atomically.
    private func performFullHydration(
        commitOid: String,
        progressHandler: SyncProgressHandler?,
        cacheFormatVersion: Int
    ) async throws {
        let manifestEntries = try collectAllManifestYamlEntries(atCommit: commitOid)
        var manifests: [any Manifest] = []
        let keksByEpoch = try preloadAllKEKs()

        let total = manifestEntries.count
        progressHandler?("Reading manifests", 0, total)
        let progressStride = max(1, total / 1_000)
        var remainingEntries = manifestEntries[...]
        try await withThrowingTaskGroup(of: ((any Manifest)?).self) { group in
            let initialTaskCount = min(Self.maxConcurrentParseTasks, remainingEntries.count)
            for _ in 0..<initialTaskCount {
                let entry = remainingEntries.removeFirst()
                group.addTask { [self] in
                    let blob = try self.repository.readBlobDataByOid(entry.blobOid)
                    return try Self.parseManifestBlob(blob, path: entry.path, keksByEpoch: keksByEpoch, registry: self.registry)
                }
            }

            var loaded = 0
            for try await parsed in group {
                if !remainingEntries.isEmpty {
                    let entry = remainingEntries.removeFirst()
                    group.addTask { [self] in
                        let blob = try self.repository.readBlobDataByOid(entry.blobOid)
                        return try Self.parseManifestBlob(blob, path: entry.path, keksByEpoch: keksByEpoch, registry: self.registry)
                    }
                }

                if let parsed {
                    manifests.append(parsed)
                }

                loaded += 1
                if loaded == total || loaded % progressStride == 0 {
                    progressHandler?("Reading manifests", loaded, total)
                }
            }
        }

        progressHandler?("Updating database", 0, 1)
        try await database.replaceAll(
            manifests: manifests,
            commitHash: commitOid,
            cacheFormatVersion: cacheFormatVersion
        )
        progressHandler?("Updating database", 1, 1)
    }

    // Lists all media manifest YAML paths at a commit for full hydration scans.
    private func collectAllManifestYamlEntries(atCommit commitOid: String) throws -> [(path: String, blobOid: String)] {
        guard let root = try repository.readTreeAtCommit(commitOid: commitOid, filepath: "manifests") else {
            return []
        }
        var output: [(path: String, blobOid: String)] = []
        for entry in root.entries {
            try collectYamlEntriesFromTree(entry: entry, entryPath: "manifests/\(entry.name)", into: &output)
        }
        return output.sorted { lhs, rhs in
            lhs.path < rhs.path
        }
    }

    // Recursively expands a tree entry into concrete YAML manifest paths.
    private func collectYamlEntriesFromTree(
        entry: GitTreeEntry,
        entryPath: String,
        into output: inout [(path: String, blobOid: String)]
    ) throws {
        switch entry.type {
        case .blob:
            if entryPath.hasSuffix(".yaml") {
                output.append((path: entryPath, blobOid: entry.oid))
            }
        case .tree:
            let children = try repository.readTreeByOid(entry.oid)
            for child in children {
                try collectYamlEntriesFromTree(entry: child, entryPath: "\(entryPath)/\(child.name)", into: &output)
            }
        case .other:
            return
        }
    }

    // Computes changed manifest YAML paths between two commits by recursively diffing subtree OIDs.
    private func listChangedManifestPathsBetweenCommits(oldCommit: String, newCommit: String) throws -> [String] {
        let oldTree = try repository.readTreeAtCommit(commitOid: oldCommit, filepath: "manifests")
        let newTree = try repository.readTreeAtCommit(commitOid: newCommit, filepath: "manifests")

        if oldTree?.oid == newTree?.oid {
            return []
        }

        var changed: Set<String> = []
        try collectChangedManifestYamlPathsBetweenTrees(
            beforeEntries: oldTree?.entries ?? [],
            afterEntries: newTree?.entries ?? [],
            basePath: "manifests",
            changedPaths: &changed
        )
        return Array(changed).sorted()
    }

    // Diffs tree entry sets and recurses into changed subtrees to avoid full-tree scans on small updates.
    private func collectChangedManifestYamlPathsBetweenTrees(
        beforeEntries: [GitTreeEntry],
        afterEntries: [GitTreeEntry],
        basePath: String,
        changedPaths: inout Set<String>
    ) throws {
        let beforeByName = Dictionary(uniqueKeysWithValues: beforeEntries.map { ($0.name, $0) })
        let afterByName = Dictionary(uniqueKeysWithValues: afterEntries.map { ($0.name, $0) })
        let allNames = Set(beforeByName.keys).union(afterByName.keys)

        for name in allNames {
            let beforeEntry = beforeByName[name]
            let afterEntry = afterByName[name]
            let path = "\(basePath)/\(name)"

            if beforeEntry == nil, let afterEntry {
                try collectChangedPathsFromEntry(afterEntry, entryPath: path, changedPaths: &changedPaths)
                continue
            }

            if let beforeEntry, afterEntry == nil {
                try collectChangedPathsFromEntry(beforeEntry, entryPath: path, changedPaths: &changedPaths)
                continue
            }

            guard let beforeEntry, let afterEntry else {
                continue
            }

            if beforeEntry.type == .tree, afterEntry.type == .tree {
                if beforeEntry.oid == afterEntry.oid {
                    continue
                }
                let beforeChildren = try repository.readTreeByOid(beforeEntry.oid)
                let afterChildren = try repository.readTreeByOid(afterEntry.oid)
                try collectChangedManifestYamlPathsBetweenTrees(
                    beforeEntries: beforeChildren,
                    afterEntries: afterChildren,
                    basePath: path,
                    changedPaths: &changedPaths
                )
                continue
            }

            if beforeEntry.type == .blob, afterEntry.type == .blob {
                if beforeEntry.oid != afterEntry.oid, path.hasSuffix(".yaml") {
                    changedPaths.insert(path)
                }
                continue
            }

            try collectChangedPathsFromEntry(beforeEntry, entryPath: path, changedPaths: &changedPaths)
            try collectChangedPathsFromEntry(afterEntry, entryPath: path, changedPaths: &changedPaths)
        }
    }

    // Expands one tree or blob entry into YAML leaves for add/delete/type-change diff cases.
    private func collectChangedPathsFromEntry(_ entry: GitTreeEntry, entryPath: String, changedPaths: inout Set<String>) throws {
        switch entry.type {
        case .blob:
            if entryPath.hasSuffix(".yaml") {
                changedPaths.insert(entryPath)
            }
        case .tree:
            let children = try repository.readTreeByOid(entry.oid)
            for child in children {
                try collectChangedPathsFromEntry(child, entryPath: "\(entryPath)/\(child.name)", changedPaths: &changedPaths)
            }
        case .other:
            return
        }
    }

    // Preloads all known KEKs so parallel parsing avoids touching mutable KEK cache state.
    private func preloadAllKEKs() throws -> [Int: Data] {
        guard repository.fileExists(at: "encryption/epochs") else {
            return [:]
        }
        let epochPaths = try repository.listFiles(in: "encryption/epochs").filter { $0.hasSuffix(".age") }
        var output: [Int: Data] = [:]
        for epochPath in epochPaths {
            let epochName = (epochPath as NSString).lastPathComponent.replacingOccurrences(of: ".age", with: "")
            guard let epoch = Int(epochName) else {
                continue
            }
            output[epoch] = try loadKEKForEpoch(epoch)
        }
        return output
    }

    // Parses one manifest blob without actor state so hydration and incremental sync can parallelize decoding.
    private nonisolated static func parseManifestBlob(
        _ blob: Data,
        path: String,
        keksByEpoch: [Int: Data],
        registry: ManifestRegistry
    ) throws -> (any Manifest)? {
        let yaml = try Self.decryptManifest(blob, keksByEpoch: keksByEpoch)
        guard let kind = Self.manifestKind(from: yaml) else {
            throw GitError.repositoryError("Missing manifest kind in YAML: \(path)")
        }
        return try registry.decode(kind: kind, yaml: yaml)
    }

    // Extracts the top-level kind field without fully decoding the YAML payload twice.
    private nonisolated static func manifestKind(from yaml: String) -> String? {
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard line.hasPrefix("kind:") else {
                continue
            }
            let value = line.dropFirst("kind:".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                return nil
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                return String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                return String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    // Decrypts encrypted manifest envelopes and rejects plaintext so a hostile
    // server cannot strip encryption and have clients accept attacker YAML.
    private nonisolated static func decryptManifest(_ content: Data, keksByEpoch: [Int: Data]) throws -> String {
        guard content.starts(with: Data("REPLYCANT-ENC-V1\n".utf8)) else {
            throw ManifestDecryptionError.plaintextManifestRejected
        }

        guard let delimiterRange = content.range(of: Data("\n---\n".utf8)) else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }

        let headerData = content.subdata(in: content.startIndex..<delimiterRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }
        let lines = headerText.components(separatedBy: "\n")
        guard lines.first == "REPLYCANT-ENC-V1" else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }
        guard let epochLine = lines.first(where: { $0.hasPrefix("kek-epoch: ") }) else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }
        let epochText = String(epochLine.dropFirst("kek-epoch: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let epoch = Int(epochText) else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }

        let payloadData = content.subdata(in: delimiterRange.upperBound..<content.endIndex)
        guard let kek = keksByEpoch[epoch] else {
            throw ManifestDecryptionError.invalidEncryptedManifest
        }
        let plaintext: Data
        do {
            plaintext = try EncryptionUtils.decryptAESGCM(ciphertext: payloadData, key: kek)
        } catch {
            guard let payloadString = String(data: payloadData, encoding: .utf8) else {
                throw error
            }
            let trimmedPayload = payloadString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let base64Payload = Data(base64Encoded: trimmedPayload) else {
                throw error
            }
            plaintext = try EncryptionUtils.decryptAESGCM(ciphertext: base64Payload, key: kek)
        }

        guard let yaml = String(data: plaintext, encoding: .utf8) else {
            throw ManifestDecryptionError.decryptedManifestInvalidUTF8
        }
        return yaml
    }
}

// Defines manifest envelope parsing failures for sync-time decryption and decoding.
enum ManifestDecryptionError: Error, Equatable {
    case plaintextManifestRejected
    case invalidEncryptedManifest
    case decryptedManifestInvalidUTF8
}
