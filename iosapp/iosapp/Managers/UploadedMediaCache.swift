import Foundation

// Defines the uploaded-media cache contract so sync and tests can share one fast skip surface.
@MainActor
protocol UploadedMediaCaching: AnyObject {
    func contains(localID: String, modifiedAt: String?) -> Bool
    func addPending(localID: String, modifiedAt: String?)
    func clear()
}

// The staged photos copied before a push. Confirming it later records
// only what that push could have sent, and a discard in between makes
// the copy stale.
struct PendingUploadSnapshot: Sendable {
    fileprivate let entries: [String: String]
    fileprivate let generation: UInt64
}

// Persists confirmed uploaded media identifiers to avoid repeating full manifest dedup scans every run.
@MainActor
final class UploadedMediaCache: UploadedMediaCaching {
    static let shared = UploadedMediaCache()

    private let fileURL: URL
    private var loaded = false
    private var persistedByLocalID: [String: String] = [:]
    private var pendingByLocalID: [String: String] = [:]
    // Bumped by clear so a push that copied the staged set beforehand
    // cannot write those photos back after a discard.
    private var generation: UInt64 = 0

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

    // Stages uploaded or skipped photos until the push that can carry
    // their commit. Writing the file here would keep a discarded commit
    // from being uploaded again.
    func addPending(localID: String, modifiedAt: String?) {
        ensureLoaded()
        pendingByLocalID[localID] = normalize(modifiedAt)
    }

    // Copies the photos staged before a push starts. Entries added while
    // that push holds the repository lock stay out of this copy.
    func pendingSnapshot() -> PendingUploadSnapshot {
        ensureLoaded()
        return PendingUploadSnapshot(entries: pendingByLocalID, generation: generation)
    }

    // Records a push's snapshot once the server accepts it. A discard
    // since the copy was taken, or a photo staged afterwards, is left
    // out so the file only names commits that push sent.
    func confirm(_ snapshot: PendingUploadSnapshot) {
        ensureLoaded()
        guard snapshot.generation == generation, !snapshot.entries.isEmpty else { return }
        for (localID, modifiedAt) in snapshot.entries {
            persistedByLocalID[localID] = modifiedAt
            if pendingByLocalID[localID] == modifiedAt {
                pendingByLocalID.removeValue(forKey: localID)
            }
        }
        persist()
    }

    // Drops staged and saved photos, and invalidates any snapshot a push
    // already copied, for discard and reset-and-resync.
    func clear() {
        generation &+= 1
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

