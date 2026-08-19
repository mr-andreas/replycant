import CommonCrypto
import CryptoKit
import Foundation

// Encapsulates the password-protected recovery-key format so backups can be restored across app reinstall.
enum RecoveryBundle {
    // Names bundle parsing and crypto failures so recovery UI can show
    // specific guidance instead of raw CryptoKit or generic errors.
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidUTF8
        case invalidEnvelopeJSON
        case unsupportedVersion
        case unsupportedCipher
        case unsupportedKDF
        case invalidKDFIterations
        case invalidNonceLength
        case invalidCiphertext
        case keyDerivationFailed
        case malformedInput
        case malformedDeepLink
        case wrongPassword

        // Maps GCM authentication failure to copy users can act on
        // when the typed password does not unlock the recovery key.
        var errorDescription: String? {
            switch self {
            case .wrongPassword:
                return "The recovery password is incorrect."
            default:
                return nil
            }
        }
    }

    // Captures PBKDF2 metadata required to derive the AES key from the user password.
    struct KDF: Codable, Equatable {
        let alg: String
        let iterations: Int
        let salt: String
    }

    // Represents the encrypted envelope that is exported into QR text and deep links.
    struct Envelope: Codable, Equatable {
        let v: Int
        let kdf: KDF
        let cipher: String
        let nonce: String
        let ciphertext: String
    }

    // Stores every field needed to recover repository access after local key material is lost.
    struct Plaintext: Codable, Equatable {
        let version: Int
        let label: String
        let uuid: String
        let created: String
        let discoveryURL: String
        let caSHA256: String
        let p256PrivateKeyPEM: String
        let agePrivateKey: String

        // Preserves the plan's JSON field names so manual tooling can read and write bundles consistently.
        enum CodingKeys: String, CodingKey {
            case version
            case label
            case uuid
            case created
            case discoveryURL = "discovery_url"
            case caSHA256 = "ca_sha256"
            case p256PrivateKeyPEM = "p256_private_key"
            case agePrivateKey = "age_private_key"
        }
    }

    // Fixes the format version so future changes can fail closed instead of mis-decoding old payloads.
    static let envelopeVersion = 1
    // Pins PBKDF2 cost to resist offline brute-force against stolen encrypted bundles.
    static let pbkdf2Iterations = 600_000
    // Keeps KDF salt at 128 bits to prevent precomputed password attacks.
    static let saltLength = 16
    // Uses 96-bit nonces because AES-GCM is defined for this size and CryptoKit enforces uniqueness.
    static let nonceLength = 12
    // Routes tap-to-open recovery links into the app without contacting any server.
    static let deepLinkPrefix = "replycant://recover?v=1&d="

    // Encrypts plaintext recovery metadata into a shareable envelope guarded by a user-chosen password.
    static func encrypt(plaintext: Plaintext, password: String) throws -> Envelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintextData = try encoder.encode(plaintext)
        let salt = randomBytes(length: saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: pbkdf2Iterations)
        let nonceData = randomBytes(length: nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintextData, using: SymmetricKey(data: key), nonce: nonce)
        guard let combined = sealed.combined else {
            throw Error.invalidCiphertext
        }
        return Envelope(
            v: envelopeVersion,
            kdf: KDF(
                alg: "PBKDF2-HMAC-SHA256",
                iterations: pbkdf2Iterations,
                salt: encodeBase64(salt)
            ),
            cipher: "AES-256-GCM",
            nonce: encodeBase64(nonceData),
            ciphertext: encodeBase64(combined)
        )
    }

    // Decrypts a bundle envelope and restores recovery metadata,
    // mapping GCM auth failure to a typed wrong-password error.
    static func decrypt(envelope: Envelope, password: String) throws -> Plaintext {
        guard envelope.v == envelopeVersion else {
            throw Error.unsupportedVersion
        }
        guard envelope.cipher == "AES-256-GCM" else {
            throw Error.unsupportedCipher
        }
        guard envelope.kdf.alg == "PBKDF2-HMAC-SHA256" else {
            throw Error.unsupportedKDF
        }
        guard envelope.kdf.iterations > 0 else {
            throw Error.invalidKDFIterations
        }
        let salt = try decodeBase64(envelope.kdf.salt)
        let nonceData = try decodeBase64(envelope.nonce)
        guard nonceData.count == nonceLength else {
            throw Error.invalidNonceLength
        }
        let ciphertext = try decodeBase64(envelope.ciphertext)
        let key = try deriveKey(password: password, salt: salt, iterations: envelope.kdf.iterations)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintextData: Data
        do {
            plaintextData = try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch CryptoKitError.authenticationFailure {
            throw Error.wrongPassword
        }
        let decoder = JSONDecoder()
        return try decoder.decode(Plaintext.self, from: plaintextData)
    }

    // Serializes an envelope to JSON so scanners and manual workflows can inspect it directly.
    static func envelopeJSONString(_ envelope: Envelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        return json
    }

    // Produces a compact base64url envelope transport used by deep links.
    static func base64EnvelopeString(_ envelope: Envelope) throws -> String {
        let json = try envelopeJSONString(envelope)
        guard let data = json.data(using: .utf8) else {
            throw Error.invalidUTF8
        }
        return data.base64URLEncodedString()
    }

    // Creates a custom-scheme link that opens the app directly into recovery mode.
    static func deepLinkString(for envelope: Envelope) throws -> String {
        deepLinkPrefix + (try base64EnvelopeString(envelope))
    }

    // Parses a scanned or pasted recovery payload from JSON, custom link, or bare base64url text.
    static func parseEnvelope(from rawInput: String) throws -> Envelope {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fromJSON = try? decodeEnvelopeJSON(from: input) {
            return fromJSON
        }

        if let encoded = extractDeepLinkPayload(from: input) {
            let decoded = try decodeBase64URL(encoded)
            guard let json = String(data: decoded, encoding: .utf8) else {
                throw Error.invalidUTF8
            }
            return try decodeEnvelopeJSON(from: json)
        }

        if let decoded = try? decodeBase64URL(input),
           let json = String(data: decoded, encoding: .utf8),
           let fromBase64 = try? decodeEnvelopeJSON(from: json) {
            return fromBase64
        }

        throw Error.malformedInput
    }

    // Decodes a standard base64 string used by envelope fields into raw bytes for crypto operations.
    static func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw Error.invalidCiphertext
        }
        return data
    }

    // Encodes raw bytes into standard base64 for deterministic JSON field storage.
    static func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    // Decodes base64url transport into raw bytes while validating malformed payload text.
    static func decodeBase64URL(_ value: String) throws -> Data {
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        guard let data = Data(base64Encoded: padded) else {
            throw Error.malformedInput
        }
        return data
    }

    // Generates cryptographically secure random bytes for salts and nonces.
    private static func randomBytes(length: Int) -> Data {
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, length, buffer.baseAddress!)
        }
        return data
    }

    // Derives an AES-256 key from the user password using PBKDF2-HMAC-SHA256.
    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        var key = Data(count: 32)
        let keyLength = key.count
        let status = password.withCString { cPassword -> Int32 in
            key.withUnsafeMutableBytes { keyBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        cPassword,
                        password.lengthOfBytes(using: .utf8),
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw Error.keyDerivationFailed
        }
        return key
    }

    // Parses envelope JSON text and validates that all required fields are present.
    private static func decodeEnvelopeJSON(from json: String) throws -> Envelope {
        guard let data = json.data(using: .utf8) else {
            throw Error.invalidUTF8
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw Error.invalidEnvelopeJSON
        }
        return envelope
    }

    // Extracts the `d` payload from a replycant deep link string for base64url decoding.
    private static func extractDeepLinkPayload(from input: String) -> String? {
        guard let url = URL(string: input),
              url.scheme?.lowercased() == "replycant" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "d" })?.value
    }
}

// Converts envelope JSON blobs into URL-safe text without introducing server-visible query payloads.
private extension Data {
    // Produces unpadded base64url text for compact deep-link payloads.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
