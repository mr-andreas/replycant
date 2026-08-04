import Foundation
import CryptoKit

/// Disk-backed LRU cache for decrypted image bytes.
///
/// Each cache instance owns a directory under the app's caches
/// folder. Entries are plain files whose names are the SHA-256
/// hex digest of the logical key (e.g. "t/photo-id"). An
/// in-memory index tracks byte sizes and last-access timestamps
/// so eviction can run without scanning the filesystem each time.
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

    /// Creates a cache backed by `directory` with the given byte
    /// budget. Call `rebuild()` after init to scan the directory
    /// and hydrate the in-memory index from existing files.
    init(directory: URL, maxBytes: Int) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// Scans the backing directory and rebuilds the in-memory
    /// index so the cache picks up files that survived across
    /// app launches.
    func rebuild() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        index.removeAll()
        totalSize = 0

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate ?? Date.distantPast
            let filename = fileURL.lastPathComponent
            index[filename] = Entry(
                filename: filename, sizeBytes: size, lastAccess: date
            )
            totalSize += size
        }
    }

    // MARK: - Public API

    /// Returns cached bytes for `key`, updating its access time,
    /// or nil on a miss.
    func data(forKey key: String) -> Data? {
        let filename = Self.filename(for: key)
        guard index[filename] != nil else { return nil }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else {
            evictCorrupt(filename: filename)
            return nil
        }
        let now = Date()
        index[filename]?.lastAccess = now
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

        let now = Date()
        index[filename] = Entry(
            filename: filename, sizeBytes: size, lastAccess: now
        )
        totalSize += size

        evictIfNeeded()
    }

    /// Deletes every cached file and resets the index.
    func removeAll() {
        for entry in index.values {
            let url = directory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
        }
        index.removeAll()
        totalSize = 0
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

    private func evictIfNeeded() {
        guard totalSize > maxBytes else { return }
        let sorted = index.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in sorted {
            guard totalSize > maxBytes else { break }
            let url = directory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
            totalSize -= entry.sizeBytes
            index.removeValue(forKey: entry.filename)
        }
    }

    /// Removes a corrupt index entry whose file can't be read.
    private func evictCorrupt(filename: String) {
        if let entry = index.removeValue(forKey: filename) {
            totalSize -= entry.sizeBytes
        }
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
