import Testing
@testable import iosapp

// Guards scanner acceptance/rejection behavior so QR validation changes do not break linking flows.
struct QRScanValidationTests {
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
}
