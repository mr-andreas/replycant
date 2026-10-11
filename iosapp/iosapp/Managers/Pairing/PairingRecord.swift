import CryptoKit
import Foundation
import GitDB

/// Client half of the discovery handshake, mirroring `pkg/pairing` in the Go
/// tree and `webapp/src/lib/pairing.ts`.
///
/// A device that has never paired knows nothing about the deployment: not the
/// CA, not where headscale lives, and it holds no tailnet credential. It shows
/// a QR carrying a freshly minted pairing secret, then waits for gitd to
/// publish a record that secret can open.
///
/// The pairing secret is the whole protection. It proves the record was
/// written in response to *this* QR. Someone who learns the discovery slot
/// still cannot plant a record, because the slot is derived from the secret
/// but opening a record requires the secret itself. Nothing in the record is
/// confidential, so there is no second layer.
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
        case malformedPayload
        case missingFields([String])
        case malformedHeadscaleURL

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
            case .malformedPayload:
                return "Pairing payload is not valid JSON."
            case .missingFields(let fields):
                return "Pairing payload is missing \(fields.joined(separator: ", "))."
            case .malformedHeadscaleURL:
                return "Headscale URL in the pairing record is not a valid URL."
            }
        }
    }

    /// 32 bytes is far beyond brute force, which is affordable because the
    /// secret only ever travels inside a QR code shown on the user's own screen.
    public static let secretByteCount = 32

    /// 16 bytes of digest keeps slots collision-free in practice while fitting
    /// well inside the 63-octet DNS label limit, since the slot is a subdomain.
    private static let slotDigestByteCount = 16

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
    /// The pairing secret is the whole credential: the ciphertext only opens
    /// under the secret from this device's QR.
    public static func open(sealed: Data, secretEncoded: String) throws -> Payload {
        let secret = try parseSecret(secretEncoded)
        let slot = slot(for: secret)
        let aad = associatedData(slot: slot)

        let wrapKey = SymmetricKey(data: derive(secret: secret, info: wrapKeyInfo, byteCount: 32))

        let payloadJSON: Data
        do {
            payloadJSON = try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed),
                using: wrapKey,
                authenticating: aad
            )
        } catch {
            throw PairingError.wrongPairingSecret
        }

        let wire: WirePayload
        do {
            wire = try JSONDecoder().decode(WirePayload.self, from: payloadJSON)
        } catch {
            throw PairingError.malformedPayload
        }
        return try toPayload(wire)
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
