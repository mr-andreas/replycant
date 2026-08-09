import Foundation

// Stores inbound recovery deep links so onboarding and settings flows can continue from external share entry points.
@MainActor
final class RecoveryDeepLinkRouter: ObservableObject {
    static let shared = RecoveryDeepLinkRouter()

    @Published private(set) var pendingInput: String?

    private init() {}

    // Parses and stores a recovery payload only when the URL matches supported recovery link formats.
    func handle(url: URL) {
        let raw = url.absoluteString
        guard (try? RecoveryBundle.parseEnvelope(from: raw)) != nil else {
            return
        }
        pendingInput = raw
    }

    // Consumes the pending input once a view has taken ownership of starting recovery UX.
    func consumePendingInput() -> String? {
        defer { pendingInput = nil }
        return pendingInput
    }
}
