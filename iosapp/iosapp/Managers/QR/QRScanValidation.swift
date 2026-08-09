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
        case .recoveryBundle:
            guard (try? RecoveryBundle.parseEnvelope(from: code)) != nil else {
                return .reject("Unsupported recovery QR code. Expected recovery envelope JSON or replycant recovery link.")
            }
            return .acceptRaw
        case .any:
            return .acceptRaw
        }
    }
}
