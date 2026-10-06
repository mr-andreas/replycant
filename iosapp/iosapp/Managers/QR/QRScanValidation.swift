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
    // The pairing secret is required: the new device cannot reach the server
    // yet, so a record gitd seals under this secret is the only way it can
    // learn how to join once this device has granted it access.
    struct DevicePublicKeyPayload: Equatable {
        let pubkey: String
        let agePubkey: String
        let name: String
        let uuid: String
        let pairingSecret: String
        let rawJSON: String
    }

    /// The first-device QR from the CA page. A fresh deployment has no device
    /// on its tailnet to pair from, so the QR is a live join credential.
    /// Clients already know gitd's address.
    struct ServerConfigPayload: Equatable {
        let ca: String
        let headscaleURL: String
        let preauthKey: String
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
            guard let pubkey = json["pubkey"],
                  let agePubkey = json["age_pubkey"],
                  let name = json["name"],
                  let uuid = json["uuid"],
                  let pairingSecret = nonBlank(json["pairing_secret"]) else {
                return .reject("Unsupported QR code format. Please scan a device-link QR containing pubkey, age_pubkey, name, uuid, and pairing_secret.")
            }
            return .acceptDevicePublicKey(
                .init(
                    pubkey: pubkey,
                    agePubkey: agePubkey,
                    name: name,
                    uuid: uuid,
                    pairingSecret: pairingSecret,
                    rawJSON: code
                )
            )
        case .recoveryBundle:
            guard (try? RecoveryBundle.parseEnvelope(from: code)) != nil else {
                return .reject("Unsupported QR code. Expected a recovery key.")
            }
            return .acceptRaw
        case .any:
            return .acceptRaw
        }
    }

    // Treats a blank field as absent. A producer that emits an empty string
    // would otherwise look like it is offering a credential it does not have.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Parses the first-device join `{ca, headscale_url, preauth_key}`.
    static func parseServerConfig(_ code: String) -> ServerConfigPayload? {
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ca = nonBlank(json["ca"]),
              let headscaleURL = nonBlank(json["headscale_url"]),
              let preauthKey = nonBlank(json["preauth_key"]) else {
            return nil
        }
        return ServerConfigPayload(ca: ca, headscaleURL: headscaleURL, preauthKey: preauthKey)
    }
}
