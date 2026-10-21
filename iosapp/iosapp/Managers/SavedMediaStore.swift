import Foundation

/// Remembers the Photos identifier created by Save.
///
/// A second tap would otherwise add another copy. The identifier is
/// checked against Photos before it counts, so deleting the asset
/// allows saving again. Add-only access cannot see that deletion, and
/// callers skip this record in that case.
@MainActor
final class SavedMediaStore {
    static let shared = SavedMediaStore()

    private let fileURL: URL
    private var loaded = false
    private var identifiersByItemID: [String: String] = [:]

    // A test passes its own file so it does not touch the app's record.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documentsURL.appendingPathComponent("replycant-saved-media.json")
        }
    }

    func localIdentifier(forItemID itemID: String) -> String? {
        ensureLoaded()
        return identifiersByItemID[itemID]
    }

    func record(localIdentifier: String, forItemID itemID: String) {
        ensureLoaded()
        identifiersByItemID[itemID] = localIdentifier
        persist()
    }

    // A library reset must forget earlier saves. The next save on a
    // wiped phone is a new copy, not a duplicate.
    func clear() {
        identifiersByItemID.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else {
            identifiersByItemID = [:]
            return
        }
        identifiersByItemID = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(identifiersByItemID) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
