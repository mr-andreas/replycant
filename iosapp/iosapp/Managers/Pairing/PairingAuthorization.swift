import Foundation
import LibGit2

/// The authorizing device's side of tailnet pairing.
///
/// A device joining over the tailnet cannot ask gitd for anything, so an
/// already-paired device has to ask on its behalf. This is that request: it
/// hands gitd the secret and age recipient from the scanned QR, and gitd seals
/// a record telling the device where the control plane is and which CA to
/// trust, and publishes it to the slot the scanned device is polling.
///
/// Authorization is inherited from the mTLS handshake - only a device already
/// in `pubkeys/` can reach the endpoint - which is the same boundary that
/// governs pushing the new device's key in the first place.
enum PairingAuthorization {
    enum AuthorizationError: LocalizedError, Equatable {
        case invalidServerURL
        case missingCredentials
        case tailnetNotEnabled
        case publishFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                return "This device has no usable server address to authorize pairing through."
            case .missingCredentials:
                return "This device has no server credentials, so it cannot authorize another device."
            case .tailnetNotEnabled:
                return "This library's server has no tailnet, so the new device should scan the connection QR instead."
            case .publishFailed(let status):
                return "The server could not publish the pairing record (HTTP \(status)). The new device is still waiting, so try again."
            }
        }
    }

    /// Where gitd serves pairing. Must match `pairingPath` in `server/gitd`.
    static let path = "/pair"

    /// Asks gitd to authorize the scanned device, returning the sealed record.
    ///
    /// The record is returned because manual-exposure deployments have no
    /// discovery service to publish to and deliver it through this response
    /// instead. It is safe to hold: it is encrypted to the scanned device's age
    /// key and authenticated under the secret from its QR, so this device
    /// cannot read it either.
    ///
    /// gitd holds the request open until the record is stored, so a success
    /// here means the other device's poll will find it.
    @discardableResult
    static func publish(
        pairingSecret: String,
        agePublicKey: String,
        serverURL: String,
        session: URLSession
    ) async throws -> Data {
        // libgit2 needs the mtls scheme to route through the custom transport,
        // so that is the form the app stores. URLSession does not know it.
        let https = MTLSTransport.convertToHTTPSScheme(
            serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let base = URL(string: https), base.host != nil else {
            throw AuthorizationError.invalidServerURL
        }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairing_secret": pairingSecret,
            "age_pubkey": agePublicKey
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthorizationError.publishFailed(0)
        }
        // A LAN-only deployment genuinely has no such endpoint, which is a
        // different situation from one that tried and failed.
        if http.statusCode == 404 {
            throw AuthorizationError.tailnetNotEnabled
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthorizationError.publishFailed(http.statusCode)
        }
        return data
    }

    /// Builds a session that can reach gitd: mTLS credentials, and the tailnet
    /// proxy when this device is itself a tailnet member.
    ///
    /// Both are required together. Without the identity gitd rejects the
    /// handshake, and without the proxy a tailnet deployment's MagicDNS name
    /// does not resolve.
    static func session() async throws -> URLSession {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw AuthorizationError.missingCredentials
        }

        let configuration = try await TailnetSessionRouter.shared
            .configuration(basedOn: .ephemeral)
        return URLSession(
            configuration: configuration,
            delegate: MTLSURLSessionAuthDelegate(clientIdentity: identity, pinnedCA: pinnedCA),
            delegateQueue: nil
        )
    }
}
