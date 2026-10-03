import CryptoKit
import Foundation
import GitDB

/// Client half of the discovery handshake, mirroring `pkg/pairing` in the Go
/// tree and `webapp/src/lib/pairing.ts`.
///
/// A device that has never paired knows nothing about the deployment: not the
/// CA, not where headscale lives, and it holds no tailnet credential. It shows
/// a QR carrying its own age public key plus a freshly minted pairing secret,
/// then waits for gitd to publish a record it alone can open.
///
/// Both halves of that record matter. The pairing secret proves the record was
/// written in response to *this* QR, and the age key proves it was written for
/// *this* device. Someone who learns the discovery slot still cannot plant a
/// record, because the slot is derived from the secret but opening a record
/// requires the secret itself.
///
/// The wire format is fixed by the Go writer, so every constant here has to
/// match `pkg/pairing/pairing.go` exactly. `PairingRecordCrossLanguageTests`
/// pins that against a record the Go implementation produced.
public enum PairingRecord {
    public enum PairingError: LocalizedError, Equatable {
        case emptySecret
        case malformedSecret
        case wrongSecretLength(Int)
        case wrongPairingSecret
        case malformedEnvelope
        case unsupportedEnvelopeVersion(Int)
        case incompleteEnvelope
        case wrongDevice
        case missingFields([String])
        case malformedHeadscaleURL
        case caFingerprintMismatch

        public var errorDescription: String? {
            switch self {
            case .emptySecret:
                return "Pairing secret is empty."
            case .malformedSecret:
                return "Pairing secret is not valid base64url."
            case .wrongSecretLength(let count):
                return "Pairing secret must be \(secretByteCount) bytes, got \(count)."
            case .wrongPairingSecret:
                return "Pairing record did not open under this pairing secret."
            case .malformedEnvelope:
                return "Pairing envelope is not valid JSON."
            case .unsupportedEnvelopeVersion(let version):
                return "Unsupported pairing envelope version \(version) (expected \(envelopeVersion))."
            case .incompleteEnvelope:
                return "Pairing envelope is missing its wrapped key or payload."
            case .wrongDevice:
                return "Pairing record was written for a different device."
            case .missingFields(let fields):
                return "Pairing payload is missing \(fields.joined(separator: ", "))."
            case .malformedHeadscaleURL:
                return "Headscale URL in the pairing record is not a valid URL."
            case .caFingerprintMismatch:
                return "The pairing record's CA does not match the fingerprint in the headscale hostname."
            }
        }
    }

    /// 32 bytes is far beyond brute force, which is affordable because the
    /// secret only ever travels inside a QR code shown on the user's own screen.
    public static let secretByteCount = 32

    /// 16 bytes of digest keeps slots collision-free in practice while fitting
    /// well inside the 63-octet DNS label limit, since the slot is a subdomain.
    private static let slotDigestByteCount = 16

    /// Bumped when the envelope layout changes, so an old client reports an
    /// unsupported version rather than a decryption failure that reads as
    /// corruption.
    private static let envelopeVersion = 1

    /// Hex characters in a tunnel hostname's CA fingerprint label, truncated
    /// from a SHA-256 of the CA's DER. Must match `caDNSLabelHexChars` in
    /// `pkg/gitcrypt`, since the deployment registers the tunnel subdomain
    /// under exactly this label.
    private static let caLabelHexChars = 32

    // Domain separation. Deriving the slot and the wrap key with different info
    // strings is what makes it safe to publish the slot as a hostname while the
    // wrap key still authenticates records.
    private static let hkdfSalt = Data("replycant/discovery/v1".utf8)
    private static let slotInfo = Data("replycant/discovery-slot/v1".utf8)
    private static let wrapKeyInfo = Data("replycant/discovery-wrap/v1".utf8)
    private static let contentKeyID = Data("replycant/discovery-content/v1".utf8)

    /// What the pairing device needs in order to join the tailnet and then
    /// reach gitd over it.
    public struct Payload: Equatable, Sendable {
        public let headscaleURL: String
        public let caPEM: String
    }

    /// A pairing attempt in progress. The encoded form goes in the QR; the slot
    /// is where the record will appear. Both derive from the same secret, so
    /// the slot never has to be transmitted to anyone.
    public struct Secret: Sendable {
        public let encoded: String
        public let slot: String
    }

    /// Mints a secret for one pairing attempt.
    ///
    /// A fresh secret per attempt is what keeps slots unlinkable and stops an
    /// abandoned attempt's record from being replayed against a later one.
    public static func createSecret() -> Secret {
        var raw = Data(count: secretByteCount)
        raw.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, secretByteCount, buffer.baseAddress!)
        }
        return Secret(encoded: encodeBase64URL(raw), slot: slot(for: raw))
    }

    /// Rejects a wrong length rather than zero-padding it, because a truncated
    /// scan would otherwise produce a slot nobody ever wrote to and surface as
    /// an unexplained pairing timeout.
    public static func parseSecret(_ encoded: String) throws -> Data {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingError.emptySecret }
        guard let raw = decodeBase64URL(trimmed) else { throw PairingError.malformedSecret }
        guard raw.count == secretByteCount else {
            throw PairingError.wrongSecretLength(raw.count)
        }
        return raw
    }

    /// Derives the subdomain a record is stored under.
    ///
    /// Writer and reader derive it independently, so the discovery API never
    /// learns who a record is for.
    public static func slot(for secret: Data) -> String {
        derive(secret: secret, info: slotInfo, byteCount: slotDigestByteCount)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Opens a record fetched from the discovery API.
    ///
    /// Both credentials are required by construction: the outer AEAD only opens
    /// under the pairing secret, and the inner content key only unwraps with
    /// the device's age key. Neither alone is enough to read a record.
    public static func open(
        sealed: Data,
        secretEncoded: String,
        ageIdentity: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Payload {
        let secret = try parseSecret(secretEncoded)
        let slot = slot(for: secret)
        let aad = associatedData(slot: slot)

        let wrapKey = SymmetricKey(data: derive(secret: secret, info: wrapKeyInfo, byteCount: 32))

        let inner: Data
        do {
            inner = try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed),
                using: wrapKey,
                authenticating: aad
            )
        } catch {
            // Almost always a record written for a different pairing attempt,
            // which is worth distinguishing from the device-key mismatch below.
            throw PairingError.wrongPairingSecret
        }

        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: inner)
        } catch {
            throw PairingError.malformedEnvelope
        }
        guard envelope.v == envelopeVersion else {
            throw PairingError.unsupportedEnvelopeVersion(envelope.v)
        }
        guard let ageBase64 = envelope.age, let payloadBase64 = envelope.payload,
              let ageBytes = Data(base64Encoded: ageBase64),
              let payloadBytes = Data(base64Encoded: payloadBase64) else {
            throw PairingError.incompleteEnvelope
        }

        let contentKey: Data
        do {
            contentKey = try AgeCrypto.decrypt(ciphertext: ageBytes, identity: ageIdentity)
        } catch {
            throw PairingError.wrongDevice
        }

        let payloadJSON = try AES.GCM.open(
            AES.GCM.SealedBox(combined: payloadBytes),
            using: SymmetricKey(data: contentKey),
            authenticating: aad
        )
        return try toPayload(try JSONDecoder().decode(WirePayload.self, from: payloadJSON))
    }

    /// Confirms the delivered CA is the one the headscale hostname commits to.
    ///
    /// In tunnel mode the hostname's first label is a fingerprint of the CA,
    /// giving the device a second check, independent of the record's
    /// encryption, that it is about to trust the CA the hostname names.
    /// Manual-exposure hostnames carry no fingerprint, so there is nothing to
    /// compare and this passes.
    public static func verifyCALabel(_ payload: Payload) throws {
        let trimmed = payload.headscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else {
            throw PairingError.malformedHeadscaleURL
        }
        let label = (host.split(separator: ".").first.map(String.init) ?? "").lowercased()
        guard label.count == caLabelHexChars,
              label.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return
        }

        let base64 = payload.caPEM
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else {
            throw PairingError.caFingerprintMismatch
        }
        let digest = SHA256.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(caLabelHexChars)
        guard digest == label else { throw PairingError.caFingerprintMismatch }
    }

    // Binds a record to its slot so a valid record cannot be relocated to
    // another slot and replayed against a different pairing attempt.
    private static func associatedData(slot: String) -> Data {
        contentKeyID + Data(slot.utf8)
    }

    // Expands the secret into an independent key for one purpose.
    private static func derive(secret: Data, info: Data, byteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: hkdfSalt,
            info: info,
            outputByteCount: byteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private struct WireEnvelope: Decodable {
        let v: Int
        let age: String?
        let payload: String?
    }

    private struct WirePayload: Decodable {
        let headscale_url: String?
        let ca_pem: String?
    }

    // Fails a payload that would leave the device stuck at "waiting for
    // authorization" forever, naming what is absent so the cause is visible.
    private static func toPayload(_ wire: WirePayload) throws -> Payload {
        var missing: [String] = []
        func require(_ value: String?, _ name: String) -> String {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                missing.append(name)
                return ""
            }
            return value
        }

        let payload = Payload(
            headscaleURL: require(wire.headscale_url, "headscale_url"),
            caPEM: require(wire.ca_pem, "ca_pem")
        )
        guard missing.isEmpty else { throw PairingError.missingFields(missing) }
        return payload
    }

    // Raw URL base64 avoids padding and the characters that get mangled when a
    // value ends up in a URL, matching Secret.String() on the Go side.
    private static func encodeBase64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ encoded: String) -> Data? {
        var normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Foundation refuses unpadded base64, which is exactly what the Go
        // writer produces.
        while normalized.count % 4 != 0 {
            normalized.append("=")
        }
        return Data(base64Encoded: normalized)
    }
}
