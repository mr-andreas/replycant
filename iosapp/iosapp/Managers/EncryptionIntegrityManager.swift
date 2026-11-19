import Combine
import GitDB

// Holds a key-set failure so the shell can keep showing it after sync
// has stopped writing. Clearing it requires a later pull that opens
// every space this device is supposed to read.
@MainActor
final class EncryptionIntegrityManager: ObservableObject {
    static let shared = EncryptionIntegrityManager()

    @Published private(set) var message: String?

    private init() {}

    func report(_ error: EncryptionIntegrityError) {
        message = error.localizedDescription
    }

    func clear() {
        message = nil
    }
}
