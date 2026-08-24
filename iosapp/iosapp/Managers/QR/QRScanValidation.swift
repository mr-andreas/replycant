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
    struct DevicePublicKeyPayload: Equatable {
        let pubkey: String
        let agePubkey: String
        let name: String
        let uuid: String
        let caHash: String?
        let rawJSON: String
    }

    // Distinguishes pairing vs recovery so connect-to-existing can route
    // after a single scan without reparsing the payload.
    enum ConnectPayloadKind: Equatable {
        case serverConfig
        case recoveryBundle
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
            guard let data = code.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return .reject("Invalid QR code. Expected valid JSON.")
            }
            guard json["ca"] != nil, json["url"] != nil else {
                return .reject("Invalid QR code. Expected server configuration with ca and url.")
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
                    caHash: json["ca_hash"],
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

    // Recognizes pairing config JSON so connect-or-recovery classification
    // can prefer the existing-device path over a recovery envelope.
    private static func isServerConfig(_ code: String) -> Bool {
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return false
        }
        return json["ca"] != nil && json["url"] != nil
    }
}
