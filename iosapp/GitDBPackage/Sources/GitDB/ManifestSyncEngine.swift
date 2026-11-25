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
    private let loadKEKForEpoch: (String, Int) throws -> Data

    // Binds one repository to one manifest cache database for deterministic sync operations.
    public init(repository: Repository, database: ManifestDatabase, registry: ManifestRegistry) {
        let kekEpochManager = KEKEpochManager(repository: repository)
        self.init(
            repository: repository,
            database: database,
            registry: registry,
            loadKEKForEpoch: { root, epoch in
                try kekEpochManager.loadKEK(epoch: epoch, root: root)
            }
        )
    }

    // Test seam that injects KEK loading so package tests can encrypt fixtures without Keychain.
    init(
        repository: Repository,
        database: ManifestDatabase,
        registry: ManifestRegistry,
        loadKEKForEpoch: @escaping (String, Int) throws -> Data
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
        try await pinSpaceModes(paths: changedPaths, commitOid: head)
        if changedPaths.isEmpty {
            // Advances checkpoint only when manifest trees are identical (e.g. rebase rewrote commit IDs).
            try await database.writeSyncedCommitHashOnly(head)
            return
        }

        var added: [any Manifest] = []
        var updated: [any Manifest] = []
        var removed: [any Manifest] = []

        // A large incremental update is what an open library applies.
        // Without these counts the bar freezes after the pack download
        // for the whole parse and the database write.
        let progressTotal = changedPaths.count
        let progressStride = max(1, progressTotal / 1_000)
        progressHandler?("Reading manifests", 0, progressTotal)
        var loadedManifests = 0

        let keksByRoot = try preloadAllKEKs(commitOid: head)
        var remainingPaths = changedPaths[...]
        try await withThrowingTaskGroup(of: IncrementalManifestPair.self) { group in
            let initialTaskCount = min(Self.maxConcurrentParseTasks, remainingPaths.count)
            for _ in 0..<initialTaskCount {
                let path = remainingPaths.removeFirst()
                group.addTask { [self] in
                    let oldManifest: (any Manifest)?
                    let root = try self.keySetRoot(for: path, commitOid: head)
                    if let oldBlob = try self.repository.readBlobDataAtCommit(commitOid: previousSynced, filepath: path) {
                        oldManifest = try Self.parseManifestBlob(oldBlob, path: path, root: root, keksByRoot: keksByRoot, registry: self.registry)
                    } else {
                        oldManifest = nil
                    }

                    let newManifest: (any Manifest)?
                    if let newBlob = try self.repository.readBlobDataAtCommit(commitOid: head, filepath: path) {
                        newManifest = try Self.parseManifestBlob(newBlob, path: path, root: root, keksByRoot: keksByRoot, registry: self.registry)
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
                        let root = try self.keySetRoot(for: path, commitOid: head)
                        let oldManifest: (any Manifest)?
                        if let oldBlob = try self.repository.readBlobDataAtCommit(commitOid: previousSynced, filepath: path) {
                            oldManifest = try Self.parseManifestBlob(oldBlob, path: path, root: root, keksByRoot: keksByRoot, registry: self.registry)
                        } else {
                            oldManifest = nil
                        }

                        let newManifest: (any Manifest)?
                        if let newBlob = try self.repository.readBlobDataAtCommit(commitOid: head, filepath: path) {
                            newManifest = try Self.parseManifestBlob(newBlob, path: path, root: root, keksByRoot: keksByRoot, registry: self.registry)
                        } else {
                            newManifest = nil
                        }
                        return IncrementalManifestPair(oldManifest: oldManifest, newManifest: newManifest)
                    }
                }

                loadedManifests += 1
                if loadedManifests == progressTotal || loadedManifests % progressStride == 0 {
                    progressHandler?("Reading manifests", loadedManifests, progressTotal)
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

        progressHandler?("Updating database", 0, 1)
        try await database.applyMutation(
            added: added,
            updated: updated,
            removed: removed,
            commitHash: head,
            cacheFormatVersion: observed
        )
        progressHandler?("Updating database", 1, 1)
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
        try await pinSpaceModes(paths: manifestEntries.map(\.path), commitOid: commitOid)
        var manifests: [any Manifest] = []
        let keksByRoot = try preloadAllKEKs(commitOid: commitOid)

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
                    let root = try self.keySetRoot(for: entry.path, commitOid: commitOid)
                    return try Self.parseManifestBlob(blob, path: entry.path, root: root, keksByRoot: keksByRoot, registry: self.registry)
                }
            }

            var loaded = 0
            for try await parsed in group {
                if !remainingEntries.isEmpty {
                    let entry = remainingEntries.removeFirst()
                    group.addTask { [self] in
                        let blob = try self.repository.readBlobDataByOid(entry.blobOid)
                        let root = try self.keySetRoot(for: entry.path, commitOid: commitOid)
                    return try Self.parseManifestBlob(blob, path: entry.path, root: root, keksByRoot: keksByRoot, registry: self.registry)
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

    // Lists manifest YAML under every space. Key files that sit beside
    // the manifests are not manifests, so only the manifests tree is walked.
    private func collectAllManifestYamlEntries(atCommit commitOid: String) throws -> [(path: String, blobOid: String)] {
        guard let spaces = try repository.readTreeAtCommit(commitOid: commitOid, filepath: EncryptionLayout.spacesPrefix) else {
            return []
        }
        var output: [(path: String, blobOid: String)] = []
        for space in spaces.entries where space.type == .tree {
            let manifestsPath = "\(EncryptionLayout.spacesPrefix)/\(space.name)/manifests"
            guard let manifests = try repository.readTreeAtCommit(commitOid: commitOid, filepath: manifestsPath) else {
                continue
            }
            for entry in manifests.entries {
                try collectYamlEntriesFromTree(entry: entry, entryPath: "\(manifestsPath)/\(entry.name)", into: &output)
            }
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
        let oldSpaces = try repository.readTreeAtCommit(commitOid: oldCommit, filepath: EncryptionLayout.spacesPrefix)
        let newSpaces = try repository.readTreeAtCommit(commitOid: newCommit, filepath: EncryptionLayout.spacesPrefix)
        let names = Set((oldSpaces?.entries ?? []).map(\.name)).union((newSpaces?.entries ?? []).map(\.name))
        var changed: Set<String> = []
        for name in names {
            let manifestsPath = "\(EncryptionLayout.spacesPrefix)/\(name)/manifests"
            let oldTree = try repository.readTreeAtCommit(commitOid: oldCommit, filepath: manifestsPath)
            let newTree = try repository.readTreeAtCommit(commitOid: newCommit, filepath: manifestsPath)
            if oldTree?.oid == newTree?.oid {
                continue
            }
            try collectChangedManifestYamlPathsBetweenTrees(
                beforeEntries: oldTree?.entries ?? [],
                afterEntries: newTree?.entries ?? [],
                basePath: manifestsPath,
                changedPaths: &changed
            )
        }
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

    // Preloads every key set the commit uses so parallel parsing does
    // not touch the KEK cache. A space without its own key set shares
    // the global epochs.
    private func preloadAllKEKs(commitOid: String) throws -> [String: [Int: Data]] {
        var roots = [EncryptionLayout.globalRoot]
        if let spaces = try repository.readTreeAtCommit(commitOid: commitOid, filepath: EncryptionLayout.spacesPrefix) {
            for space in spaces.entries where space.type == .tree {
                let current = EncryptionLayout.spaceKeySetRoot(space.name) + "/current"
                if try repository.readBlobDataAtCommit(commitOid: commitOid, filepath: current) != nil {
                    roots.append(EncryptionLayout.spaceKeySetRoot(space.name))
                }
            }
        }
        var output: [String: [Int: Data]] = [:]
        for root in roots {
            guard let epochs = try repository.readTreeAtCommit(commitOid: commitOid, filepath: "\(root)/epochs") else {
                continue
            }
            var byEpoch: [Int: Data] = [:]
            for entry in epochs.entries where entry.name.hasSuffix(".age") {
                let epochName = (entry.name as NSString).deletingPathExtension
                guard let epoch = Int(epochName) else {
                    continue
                }
                byEpoch[epoch] = try loadKEKForEpoch(root, epoch)
            }
            output[root] = byEpoch
        }
        return output
    }

    // The path picks the key set. A space that gained or lost its own
    // key set after this cache first saw it is refused before any row
    // is written.
    private func pinSpaceModes(paths: [String], commitOid: String) async throws {
        var seen: Set<String> = []
        for path in paths {
            guard let space = EncryptionLayout.space(from: path), seen.insert(space).inserted else {
                continue
            }
            let own = try keySetRoot(for: path, commitOid: commitOid) != EncryptionLayout.globalRoot
            let mode = own ? "own" : "global"
            if let stored = try await database.spaceMode(space), stored != mode {
                throw EncryptionIntegrityError(
                    space: space,
                    path: path,
                    reason: "the space changed key set"
                )
            }
            if try await database.spaceMode(space) == nil {
                try await database.setSpaceMode(space, mode)
            }
        }
    }

    private nonisolated func keySetRoot(for path: String, commitOid: String) throws -> String {
        guard let space = EncryptionLayout.space(from: path) else {
            return EncryptionLayout.globalRoot
        }
        let current = EncryptionLayout.spaceKeySetRoot(space) + "/current"
        if try repository.readBlobDataAtCommit(commitOid: commitOid, filepath: current) != nil {
            return EncryptionLayout.spaceKeySetRoot(space)
        }
        return EncryptionLayout.globalRoot
    }

    // Parses one manifest blob without actor state so hydration and incremental sync can parallelize decoding.
    private nonisolated static func parseManifestBlob(
        _ blob: Data,
        path: String,
        root: String,
        keksByRoot: [String: [Int: Data]],
        registry: ManifestRegistry
    ) throws -> (any Manifest)? {
        let yaml = try Self.decryptManifest(blob, path: path, root: root, keksByRoot: keksByRoot)
        guard let kind = Self.manifestKind(from: yaml) else {
            throw EncryptionIntegrityError(space: EncryptionLayout.space(from: path) ?? path, path: path, reason: "the manifest has no kind")
        }
        return try registry.decode(
            kind: kind,
            yaml: yaml,
            space: EncryptionLayout.space(from: path) ?? ""
        )
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
    private nonisolated static func decryptManifest(
        _ content: Data,
        path: String,
        root: String,
        keksByRoot: [String: [Int: Data]]
    ) throws -> String {
        let space = EncryptionLayout.space(from: path) ?? path
        guard content.starts(with: Data("REPLYCANT-ENC-V1\n".utf8)) else {
            throw EncryptionIntegrityError(space: space, path: path, reason: "the manifest is plaintext")
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
        guard let kek = keksByRoot[root]?[epoch] else {
            throw EncryptionIntegrityError(space: space, path: path, reason: "epoch \(epoch) is missing")
        }
        let plaintext: Data
        do {
            plaintext = try Self.decryptManifestPayload(payloadData, key: kek)
        } catch {
            throw EncryptionIntegrityError(space: space, path: path, reason: "the manifest did not open")
        }

        guard let yaml = String(data: plaintext, encoding: .utf8) else {
            throw ManifestDecryptionError.decryptedManifestInvalidUTF8
        }
        return yaml
    }

    // Some writers store the AES payload as base64 text inside the
    // envelope. Both forms are the same ciphertext; a failure of both
    // means this key set cannot open the object.
    private nonisolated static func decryptManifestPayload(_ payload: Data, key: Data) throws -> Data {
        do {
            return try EncryptionUtils.decryptAESGCM(ciphertext: payload, key: key)
        } catch {
            guard let payloadString = String(data: payload, encoding: .utf8) else {
                throw error
            }
            let trimmedPayload = payloadString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let base64Payload = Data(base64Encoded: trimmedPayload) else {
                throw error
            }
            return try EncryptionUtils.decryptAESGCM(ciphertext: base64Payload, key: key)
        }
    }
}

// Defines manifest envelope parsing failures for sync-time decryption and decoding.
enum ManifestDecryptionError: Error, Equatable {
    case plaintextManifestRejected
    case invalidEncryptedManifest
    case decryptedManifestInvalidUTF8
}
