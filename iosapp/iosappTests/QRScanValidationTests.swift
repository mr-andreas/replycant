import Foundation
import Testing
@testable import iosapp

// Guards scanner acceptance/rejection behavior so QR validation changes do not break linking flows.
struct QRScanValidationTests {
    private static let recoveryEnvelopeJSON = #"{"cipher":"AES-256-GCM","ciphertext":"oKGio6Slpqeoqaqr0EzS5x5qtZpeXHPGYcpm1oF81Re4W8yYCJdmu3tiDLQXmL0f4gYcuHqiNPPqJmN50dHHWeyKued8vx6ZYJw9SO7IY+MiSSrWDDzSfwLRTZHKl5kU6LeAv7qJ+rLqGHnTzS3b+G2JaBeYtHls7l5dw8q50DkBYyg2AqkLX2WQzdEVNFbLuv/yfASS2lPds3n/OL751nz97b9otAhHdTm2EIN9TpJX0SG9hfPy5CEVbw7M3xVwo5AMOm+sqa6WUb7Vx+d3r+k+mh3IkfLzNWXVV7e4m7LNLc4fUOTX4OfTLveEL7kRpT8ii/izq0+bFENDIp2AGuZWSsKm9JMMuq8yLFaGMu43EfxLeRXuCmxnlzfvT8Khxlfm8TJecTs4OAq/n3pzBGXnM8d49bWbETxeMgxomUbfr46PCyZ7Z+Fce++YU0ZcOMvUXLQrj46+YWqffSwW51Grr67LT/BJmrs2MOpPTxCHeSmRY+UNMvpQjlRbG0PmbTsbGApW4LLgkfNLCJ9ikVd6fe19UZboG4C+Xu0HBFL6BLTqdjiO4gn8Iw7ocpbyOwYoDV2lmEKVK1ZqgQTTqVQ4ZsDVSutE5yY6pFQRwXEkjWafkFrC/g4enLS95P94jcV2Tf2jxPigvNlQOG1ofY9rFtM9DGIwRuG1KuQoDugOrPAeuowj68GTr7z8xet0qeQyFIazXcyo4kFK9FsRc15atjvSZ+/r+89vf8yrgs5qWEU5dzksoaJaK5+MqncqQ3StvBpjIxFXWn7cFfP5n4UShOnmNHuE6JWLI3WDHsMwRArvMw==","kdf":{"alg":"PBKDF2-HMAC-SHA256","iterations":600000,"salt":"AAECAwQFBgcICQoLDA0ODw=="},"nonce":"oKGio6Slpqeoqaqr","v":1}"#
    // Verifies server-config mode accepts payloads required for onboarding setup.
    @Test func serverConfigAcceptsRequiredFields() {
        let code = #"{"ca":"pem","url":"https://example.com/repo.git"}"#
        let decision = QRScanValidation.validate(code: code, mode: .serverConfig)
        #expect(decision == .acceptRaw)
    }

    // Verifies device-link mode extracts validated fields for downstream linking without reparsing.
    @Test func devicePublicKeyExtractsPayload() {
        let code = #"{"pubkey":"ssh-ed25519 AAAA test","age_pubkey":"age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq","name":"iphone","uuid":"abcd"}"#
        let decision = QRScanValidation.validate(code: code, mode: .devicePublicKey)

        guard case .acceptDevicePublicKey(let payload) = decision else {
            Issue.record("Expected device payload acceptance")
            return
        }

        #expect(payload.pubkey == "ssh-ed25519 AAAA test")
        #expect(payload.agePubkey == "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq")
        #expect(payload.name == "iphone")
        #expect(payload.uuid == "abcd")
        #expect(payload.caHash == nil)
        #expect(payload.rawJSON == code)
    }

    // Verifies optional webapp CA hash is preserved so linking flow can enforce same-server authorization.
    @Test func devicePublicKeyExtractsOptionalCAHash() {
        let code = #"{"pubkey":"ssh-ed25519 AAAA test","age_pubkey":"age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq","name":"webapp","uuid":"abcd","ca_hash":"abc123"}"#
        let decision = QRScanValidation.validate(code: code, mode: .devicePublicKey)

        guard case .acceptDevicePublicKey(let payload) = decision else {
            Issue.record("Expected device payload acceptance")
            return
        }

        #expect(payload.caHash == "abc123")
    }

    // Verifies invalid JSON is rejected quickly so scanner can continue without committing.
    @Test func invalidJSONIsRejected() {
        let decision = QRScanValidation.validate(code: "not-json", mode: .devicePublicKey)

        guard case .reject(let message) = decision else {
            Issue.record("Expected rejection for invalid JSON")
            return
        }

        #expect(message.contains("Invalid QR code"))
    }

    // Verifies wrong device-link shape is rejected with a device-specific guidance message.
    @Test func devicePublicKeyMissingFieldsIsRejected() {
        let code = #"{"name":"iphone"}"#
        let decision = QRScanValidation.validate(code: code, mode: .devicePublicKey)

        guard case .reject(let message) = decision else {
            Issue.record("Expected rejection for missing required fields")
            return
        }

        #expect(message.contains("device-link QR"))
    }

    // Verifies recovery mode accepts raw encrypted envelope JSON used by offline QR backups.
    @Test func recoveryBundleAcceptsEnvelopeJSON() {
        let decision = QRScanValidation.validate(code: Self.recoveryEnvelopeJSON, mode: .recoveryBundle)
        #expect(decision == .acceptRaw)
    }

    // Verifies recovery mode accepts custom-scheme links used by share sheets.
    @Test func recoveryBundleAcceptsDeepLink() {
        let envelope = Data(Self.recoveryEnvelopeJSON.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decision = QRScanValidation.validate(
            code: "replycant://recover?v=1&d=\(envelope)",
            mode: .recoveryBundle
        )
        #expect(decision == .acceptRaw)
    }
}
