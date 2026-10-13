import Foundation

#if DEBUG
// Parses the debug-only device-link URL. A simulator has no camera, so
// the already-paired device receives the new device's QR JSON this way
// instead of scanning it. Release builds omit it: the link grants
// access to whatever key it carries.
enum DebugDeviceLink {
    static let scheme = "replycant"
    static let host = "debug-link-device"

    // Returns the device fields only when they are the same payload the
    // camera would accept. A recovery link or a first-device join is
    // ignored so this route cannot start the wrong flow.
    static func payload(
        from url: URL
    ) -> QRScanValidation.DevicePublicKeyPayload? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              case .acceptDevicePublicKey(let payload) = QRScanValidation.validate(
                code: raw,
                mode: .devicePublicKey
              ) else {
            return nil
        }
        return payload
    }
}

// Starts a grant from a link opened on an already-paired device.
// The linking scanner is a sheet without a navigation bar, so a
// simulator has no control that can read this payload.
@MainActor
final class DebugDeviceLinkRouter {
    static let shared = DebugDeviceLinkRouter()

    private let grant: (QRScanValidation.DevicePublicKeyPayload) async throws -> Void
    private var grantInFlight = false

    // Tests pass a grant that does not touch the repository. The app
    // uses the live one, which commits the key and publishes the record.
    init(
        grant: ((QRScanValidation.DevicePublicKeyPayload) async throws -> Void)? = nil
    ) {
        self.grant = grant ?? Self.liveGrant
    }

    // Drops the link unless it is a real device QR. Other replycant
    // URLs belong to recovery and bootstrap. A second link is dropped
    // while a grant is running so one QR cannot be pushed twice.
    func handle(url: URL) {
        guard let payload = DebugDeviceLink.payload(from: url) else {
            return
        }
        guard !grantInFlight else {
            log(
                "Ignoring device-link while a grant is already running",
                context: "DebugDeviceLink"
            )
            return
        }
        grantInFlight = true
        let grant = self.grant
        Task {
            defer { self.grantInFlight = false }
            do {
                try await grant(payload)
                log(
                    "Granted access to \(payload.name)",
                    context: "DebugDeviceLink"
                )
            } catch {
                logError(
                    "Debug device link failed: \(error.localizedDescription)",
                    context: "DebugDeviceLink"
                )
            }
        }
    }

    // The same grant the scanner runs after a successful scan.
    private static func liveGrant(
        _ payload: QRScanValidation.DevicePublicKeyPayload
    ) async throws {
        try await DeviceLinking.grantAccess(
            pubkey: payload.pubkey,
            agePubkey: payload.agePubkey,
            name: payload.name,
            uuid: payload.uuid,
            pairingSecret: payload.pairingSecret
        )
    }
}
#endif
