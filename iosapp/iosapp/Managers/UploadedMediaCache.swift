import Foundation

// Defines the uploaded-media cache contract so sync and tests can share one fast skip surface.
@MainActor
protocol UploadedMediaCaching: AnyObject {
    func contains(localID: String, modifiedAt: String?) -> Bool
    func markConfirmed(localID: String, modifiedAt: String?)
    func addPending(localID: String, modifiedAt: String?)
    func flushPending()
    func clear()
}

// Persists confirmed uploaded media identifiers to avoid repeating full manifest dedup scans every run.
@MainActor
final class UploadedMediaCache: UploadedMediaCaching {
    static let shared = UploadedMediaCache()

    private let fileURL: URL
    private var loaded = false
    private var persistedByLocalID: [String: String] = [:]
    private var pendingByLocalID: [String: String] = [:]

    // Uses a file in Documents so uninstall clears state and reset flows can wipe it deliberately.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documentsURL.appendingPathComponent("replycant-upload-cache.json")
        }
    }

    // Answers fast localID+modifiedAt membership checks before expensive manifest database queries.
    func contains(localID: String, modifiedAt: String?) -> Bool {
        ensureLoaded()
        return persistedByLocalID[localID] == normalize(modifiedAt)
    }

    // Persists entries already confirmed on server so reruns can skip immediately without waiting for push callbacks.
    func markConfirmed(localID: String, modifiedAt: String?) {
        ensureLoaded()
        let normalizedModifiedAt = normalize(modifiedAt)
        persistedByLocalID[localID] = normalizedModifiedAt
        pendingByLocalID.removeValue(forKey: localID)
        persist()
    }

    // Stages uploaded/skipped entries until a later push confirms they are safe to persist.
    func addPending(localID: String, modifiedAt: String?) {
        ensureLoaded()
        pendingByLocalID[localID] = normalize(modifiedAt)
    }

    // Commits pending entries after push success so cache never records rolled-back local commits.
    func flushPending() {
        ensureLoaded()
        guard !pendingByLocalID.isEmpty else { return }
        for (localID, modifiedAt) in pendingByLocalID {
            persistedByLocalID[localID] = modifiedAt
        }
        pendingByLocalID.removeAll()
        persist()
    }

    // Clears both persisted and pending entries for reset-and-resync and reinstall-like behavior.
    func clear() {
        persistedByLocalID.removeAll()
        pendingByLocalID.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    // Loads once lazily to keep startup cheap while still supporting immediate cache checks during sync.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else {
            persistedByLocalID = [:]
            return
        }
        persistedByLocalID = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    // Stores only confirmed entries so crash-before-push cannot produce false-positive cache hits.
    private func persist() {
        guard let data = try? JSONEncoder().encode(persistedByLocalID) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // Normalizes optional modifiedAt values into a stable dictionary representation.
    private func normalize(_ modifiedAt: String?) -> String {
        modifiedAt ?? ""
    }
}

