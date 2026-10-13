import Foundation

#if DEBUG
// Parses the debug-only bootstrap link. A simulator has no camera, so an
// agent opens this URL with the CA page's join JSON instead of scanning.
// Release builds omit it: the link can point the app at any server.
enum DebugBootstrapLink {
    static let scheme = "replycant"
    static let host = "debug-bootstrap"

    // Returns the join JSON only when it is the same payload the camera
    // would accept. Anything else, including a recovery link, is ignored
    // so this route cannot start the wrong flow.
    static func payload(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              QRScanValidation.parseServerConfig(raw) != nil else {
            return nil
        }
        return raw
    }
}

// Holds a bootstrap link that arrived before onboarding was on screen.
// A cold launch from simctl delivers the URL first; the view reads it
// once it exists.
@MainActor
final class DebugBootstrapLinkRouter: ObservableObject {
    static let shared = DebugBootstrapLinkRouter()

    @Published private(set) var pendingPayload: String?

    private init() {}

    // Keeps a link only when it is a real join payload. Other replycant
    // URLs belong to recovery and must not land here.
    func handle(url: URL) {
        guard let payload = DebugBootstrapLink.payload(from: url) else {
            return
        }
        pendingPayload = payload
    }

    // Hands the payload to onboarding once, so a later appearance does
    // not bootstrap a second time with a spent key.
    func consumePendingPayload() -> String? {
        defer { pendingPayload = nil }
        return pendingPayload
    }
}
#endif
