import Foundation
import CryptoKit

// Implements a compact multi-recipient age-like envelope so KEK epochs can be shared across authorized devices.
public enum AgeCrypto {
    // Surfaces envelope parsing and cryptographic failures that must fail closed for key confidentiality.
    public enum Error: Swift.Error {
        case emptyRecipients
        case invalidFormat
        case invalidRecipientLine
        case invalidBase64
        case failedToDecryptFileKey
    }

    private static let header = "age-encryption.org/v1"
    private static let recipientPrefix = "-> X25519 "
    private static let payloadPrefix = "payload "
    private static let wrapSalt = Data("replycant-age-wrap-salt".utf8)
    private static let wrapInfo = Data("replycant-age-wrap-info".utf8)

    // Encrypts plaintext once and wraps the file key for each recipient to keep KEK distribution cheap during device changes.
    public static func encrypt(plaintext: Data, recipients: [Curve25519.KeyAgreement.PublicKey]) throws -> Data {
        guard !recipients.isEmpty else {
            throw Error.emptyRecipients
        }

        let fileKeyData = randomBytes(count: 32)
        let fileKey = SymmetricKey(data: fileKeyData)
        let payloadBox = try ChaChaPoly.seal(plaintext, using: fileKey)

        var lines: [String] = [header]
        lines.reserveCapacity(recipients.count + 2)

        for recipient in recipients {
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrapSalt, sharedInfo: wrapInfo, outputByteCount: 32)
            let wrappedFileKey = try ChaChaPoly.seal(fileKeyData, using: wrapKey)
            let ephData = ephemeral.publicKey.rawRepresentation.base64EncodedString()
            let wrappedData = wrappedFileKey.combined.base64EncodedString()
            lines.append("\(recipientPrefix)\(ephData) \(wrappedData)")
        }

        lines.append(payloadPrefix + payloadBox.combined.base64EncodedString())
        return Data(lines.joined(separator: "\n").utf8)
    }

    // Decrypts payload by trying each recipient stanza until one unwraps the shared file key for the local identity.
    public static func decrypt(ciphertext: Data, identity: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let text = String(data: ciphertext, encoding: .utf8) else {
            throw Error.invalidFormat
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == header else {
            throw Error.invalidFormat
        }

        var wrappedLines: [String] = []
        var payloadCombined: Data?

        for line in lines.dropFirst() {
            if line.hasPrefix(recipientPrefix) {
                wrappedLines.append(line)
            } else if line.hasPrefix(payloadPrefix) {
                let b64 = String(line.dropFirst(payloadPrefix.count))
                guard let payloadData = Data(base64Encoded: b64) else {
                    throw Error.invalidBase64
                }
                payloadCombined = payloadData
            }
        }

        guard let payload = payloadCombined else {
            throw Error.invalidFormat
        }

        let fileKeyData = try unwrapFileKey(lines: wrappedLines, identity: identity)
        let fileKey = SymmetricKey(data: fileKeyData)
        let sealedPayload = try ChaChaPoly.SealedBox(combined: payload)
        return try ChaChaPoly.open(sealedPayload, using: fileKey)
    }

    // Finds the stanza matching the local private key so one device can decrypt without trial-decrypting full payload repeatedly.
    private static func unwrapFileKey(lines: [String], identity: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        for line in lines {
            let body = String(line.dropFirst(recipientPrefix.count))
            let components = body.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count == 2 else {
                throw Error.invalidRecipientLine
            }

            guard let ephData = Data(base64Encoded: String(components[0])),
                  let wrappedData = Data(base64Encoded: String(components[1])) else {
                throw Error.invalidBase64
            }

            let ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData)
            let shared = try identity.sharedSecretFromKeyAgreement(with: ephemeralPublic)
            let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrapSalt, sharedInfo: wrapInfo, outputByteCount: 32)

            if let sealed = try? ChaChaPoly.SealedBox(combined: wrappedData),
               let unwrapped = try? ChaChaPoly.open(sealed, using: wrapKey),
               unwrapped.count == 32 {
                return unwrapped
            }
        }
        throw Error.failedToDecryptFileKey
    }

    // Generates cryptographically strong random bytes for per-file keys and nonces.
    private static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return data
    }
}
