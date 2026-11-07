import Foundation
import CryptoKit

/// One file found by the deferred directory walk.
///
/// Kept outside the cache actor so the walk can run off the actor
/// that serves thumbnail reads.
private struct ScannedCacheFile: Sendable {
    let sizeBytes: Int
    let lastAccess: Date
}

/// Disk-backed LRU cache for decrypted image bytes.
///
/// Each cache instance owns a directory under the app's caches
/// folder. Entries are plain files whose names are the SHA-256
/// hex digest of the logical key (e.g. "t/photo-id"). An
/// in-memory index tracks byte sizes and last-access timestamps
/// so eviction can run without scanning the filesystem each time.
///
/// Until that index is published, a read opens the one file named
/// by the key. The directory walk that publishes the index happens
/// after the first photos, so launch does not list every cached
/// file before those thumbnails can appear.
///
/// The actor is safe to call from any task, including detached
/// loader tasks on background threads.
actor DiskImageCache {

    private struct Entry {
        let filename: String
        var sizeBytes: Int
        var lastAccess: Date
    }

    private let directory: URL
    private var maxBytes: Int
    private var index: [String: Entry] = [:]
    private var totalSize: Int = 0
    /// False until a directory walk has published a complete budget.
    /// Reads before that open the hashed file, because an empty index
    /// would hide thumbnails that are already on disk.
    private var indexPublished = false
    /// Bumped when the directory is cleared so an in-flight walk
    /// cannot put those files back into the index.
    private var clearGeneration = 0
    /// Names removed while a walk is in flight. The walk's snapshot
    /// may still contain them.
    private var tombstones: Set<String> = []
    /// The one directory walk for this cache. Launch and Settings share it.
    private var indexTask: Task<Void, Never>?

    /// Creates a cache backed by `directory` with the given byte
    /// budget. The directory exists immediately so a store can land
    /// before the size index has been built.
    init(directory: URL, maxBytes: Int) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Walks the directory once. A second caller waits for that same
    /// walk instead of listing the cache again.
    func ensureIndex() async {
        if indexTask == nil {
            indexTask = Task { await self.rebuild() }
        }
        await indexTask?.value
    }

    /// Rebuilds the size index from the directory.
    ///
    /// The walk runs off this actor so a thumbnail read is not stuck
    /// behind a listing of the whole cache. Reads during the walk
    /// still open files by name. A clear that lands during the walk
    /// discards the snapshot so deleted files are not restored.
    func rebuild() async {
        let directory = self.directory
        index.removeAll()
        totalSize = 0
        tombstones.removeAll()
        indexPublished = false
        let generation = clearGeneration
        let scanned = await Task.detached(priority: .utility) {
            Self.scan(directory)
        }.value
        publish(scanned, startingGeneration: generation)
    }

    // MARK: - Public API

    /// Returns cached bytes for `key`, or nil on a miss.
    ///
    /// Before the size index is published, this opens the hashed
    /// path. A hit does not create an index entry; the directory
    /// walk is what makes the byte budget complete. After the index
    /// is published, a name it does not contain is a miss and does
    /// not touch the filesystem, so scrolling through uncached
    /// photos does not pay a failed open per tier.
    func data(forKey key: String) -> Data? {
        let filename = Self.filename(for: key)
        if indexPublished && index[filename] == nil {
            return nil
        }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else {
            if index[filename] != nil {
                discard(filename)
            }
            return nil
        }
        let now = Date()
        if index[filename] != nil {
            index[filename]?.lastAccess = now
        }
        // The walk uses the file's modification date as last access.
        // Touching it here lets a read that happens during the walk
        // count as recent once the snapshot is taken.
        try? FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: url.path
        )
        return data
    }

    /// Writes `data` under `key`, evicting LRU entries if needed.
    /// Silently drops writes that exceed the total budget.
    func store(_ data: Data, forKey key: String) {
        let size = data.count
        guard size <= maxBytes else { return }

        let filename = Self.filename(for: key)
        let url = directory.appendingPathComponent(filename)

        if let existing = index[filename] {
            totalSize -= existing.sizeBytes
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }

        // A rewrite of a name evicted during the walk has to survive
        // the snapshot, which may still list the deleted file.
        tombstones.remove(filename)
        let now = Date()
        index[filename] = Entry(
            filename: filename, sizeBytes: size, lastAccess: now
        )
        totalSize += size

        evictIfNeeded()
    }

    /// Drops one cached file so the next read misses. A thumbnail
    /// that cannot be decoded stays blank until this entry is gone.
    func remove(forKey key: String) {
        discard(Self.filename(for: key))
    }

    /// Deletes the cache directory, not only names already in the
    /// index, so a clear before the walk still removes the previous
    /// session's files. Recreates the directory for later stores.
    func removeAll() {
        clearGeneration += 1
        tombstones.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        index.removeAll()
        totalSize = 0
        indexPublished = true
    }

    /// Adjusts the byte budget and immediately evicts if the new
    /// limit is smaller than the current footprint.
    func setMaxBytes(_ newMax: Int) {
        maxBytes = newMax
        evictIfNeeded()
    }

    var currentSizeBytes: Int { totalSize }
    var itemCount: Int { index.count }

    // MARK: - Internals

    /// Deterministic filename from a logical key so the same key
    /// always maps to the same file across sessions.
    static func filename(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Lists the cache directory. Runs off the cache actor so
    /// thumbnail reads are not serialized behind this walk.
    private nonisolated static func scan(_ directory: URL) -> [String: ScannedCacheFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [:] }

        var found: [String: ScannedCacheFile] = [:]
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            let filename = fileURL.lastPathComponent
            found[filename] = ScannedCacheFile(
                sizeBytes: values.fileSize ?? 0,
                lastAccess: values.contentModificationDate ?? Date.distantPast
            )
        }
        return found
    }

    /// Publishes the walked files as the size index.
    ///
    /// Stores that landed during the walk win over the snapshot.
    /// Names evicted during the walk are dropped, because the
    /// snapshot may still contain them. A clear during the walk
    /// discards the snapshot entirely.
    private func publish(
        _ scanned: [String: ScannedCacheFile],
        startingGeneration: Int
    ) {
        guard startingGeneration == clearGeneration else {
            indexPublished = true
            return
        }

        var merged: [String: Entry] = [:]
        for (filename, file) in scanned {
            if tombstones.contains(filename) { continue }
            merged[filename] = Entry(
                filename: filename,
                sizeBytes: file.sizeBytes,
                lastAccess: file.lastAccess
            )
        }
        for (filename, entry) in index {
            if tombstones.contains(filename) { continue }
            merged[filename] = entry
        }
        index = merged
        tombstones.removeAll()
        totalSize = merged.values.reduce(0) { $0 + $1.sizeBytes }
        indexPublished = true
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard totalSize > maxBytes else { return }
        let sorted = index.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in sorted {
            guard totalSize > maxBytes else { break }
            discard(entry.filename)
        }
    }

    /// Drops one name from the budget and from disk. Recorded so an
    /// in-flight directory walk does not restore it.
    private func discard(_ filename: String) {
        tombstones.insert(filename)
        if let entry = index.removeValue(forKey: filename) {
            totalSize -= entry.sizeBytes
        }
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
