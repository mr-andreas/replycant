import Foundation

// Centralizes QR payload validation so scanner behavior stays consistent and unit-testable.
enum QRScanValidation {
    // Represents scan decisions so camera code can continue or stop without duplicating validation.
    enum Decision: Equatable {
        case acceptRaw
        case acceptDevicePublicKey(DevicePublicKeyPayload)
        case reject(String)
    }

    // Carries validated device-link fields to avoid reparsing JSON downstream.
    //
    // caHash and pairingSecret are both optional because they represent the two
    // onboarding paths a scanned device can be asking for. A device that could
    // reach the server over the LAN sends caHash, tying its request to one
    // trust root. A device that cannot reach the server at all has no trust
    // anchor yet and sends pairingSecret instead, so this device can ask gitd
    // to seal a pairing record under it.
    struct DevicePublicKeyPayload: Equatable {
        let pubkey: String
        let agePubkey: String
        let name: String
        let uuid: String
        let caHash: String?
        let pairingSecret: String?
        let rawJSON: String
    }

    // Distinguishes pairing vs recovery so connect-to-existing can route
    // after a single scan without reparsing the payload.
    enum ConnectPayloadKind: Equatable {
        case serverConfig
        case recoveryBundle
    }

    /// The two shapes the CA page can emit.
    ///
    /// LAN-only gitd still advertises `{ca, url}`. A tailnet deployment has
    /// no reachable gitd URL yet, so the first-device QR is a live join
    /// credential instead. Clients already know gitd's address.
    enum ServerConfigPayload: Equatable {
        case lan(ca: String, url: String)
        case tailnet(ca: String, headscaleURL: String, preauthKey: String)
    }

    // Classifies a connect-flow scan so recovery QRs can reuse the same
    // camera step as a server-config pairing QR.
    static func connectPayloadKind(code: String) -> ConnectPayloadKind? {
        if isServerConfig(code) {
            return .serverConfig
        }
        if (try? RecoveryBundle.parseEnvelope(from: code)) != nil {
            return .recoveryBundle
        }
        return nil
    }

    // Validates scanned QR content for a specific flow and returns the next scanner action.
    static func validate(code: String, mode: QRCodeScannerView.ValidationMode) -> Decision {
        switch mode {
        case .serverConfig:
            guard parseServerConfig(code) != nil else {
                return .reject("Invalid QR code. Expected server configuration.")
            }
            return .acceptRaw
        case .devicePublicKey:
            guard let data = code.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return .reject("Invalid QR code. Expected valid JSON.")
            }
            guard let pubkey = json["pubkey"], let agePubkey = json["age_pubkey"], let name = json["name"], let uuid = json["uuid"] else {
                return .reject("Unsupported QR code format. Please scan a device-link QR containing pubkey, age_pubkey, name, and uuid.")
            }
            return .acceptDevicePublicKey(
                .init(
                    pubkey: pubkey,
                    agePubkey: agePubkey,
                    name: name,
                    uuid: uuid,
                    caHash: nonBlank(json["ca_hash"]),
                    pairingSecret: nonBlank(json["pairing_secret"]),
                    rawJSON: code
                )
            )
        case .connectOrRecovery:
            guard connectPayloadKind(code: code) != nil else {
                return .reject("Unsupported QR code. Expected server configuration or a recovery key.")
            }
            return .acceptRaw
        case .any:
            return .acceptRaw
        }
    }

    // Treats a blank field as absent so the two onboarding paths stay
    // distinguishable. A producer that emits an empty string would otherwise
    // look like it is offering a path it cannot complete.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // Recognizes pairing config JSON so connect-or-recovery classification
    // can prefer the existing-device path over a recovery envelope.
    private static func isServerConfig(_ code: String) -> Bool {
        parseServerConfig(code) != nil
    }

    /// Accepts either LAN `{ca, url}` or a first-device tailnet join
    /// `{ca, headscale_url, preauth_key}`.
    static func parseServerConfig(_ code: String) -> ServerConfigPayload? {
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ca = nonBlank(json["ca"]) else {
            return nil
        }
        if let url = nonBlank(json["url"]) {
            return .lan(ca: ca, url: url)
        }
        if let headscaleURL = nonBlank(json["headscale_url"]),
           let preauthKey = nonBlank(json["preauth_key"]) {
            return .tailnet(ca: ca, headscaleURL: headscaleURL, preauthKey: preauthKey)
        }
        return nil
    }
}
