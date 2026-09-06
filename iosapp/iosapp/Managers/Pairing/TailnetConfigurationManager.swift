import Foundation

/// Remembers what this device needs in order to rejoin its deployment's tailnet
/// after a restart.
///
/// Mirrors `TailnetConfigRecord` in `webapp/src/lib/tailnet.ts`, because both
/// clients derive the same thing from the same pairing record and a divergence
/// would show up as one platform being unable to reconnect.
///
/// Notably absent is the pre-auth key. It is single-use and expires in minutes,
/// and the node's own key material persists in the tsnet state directory, so a
/// rejoin needs no credential beyond the device's existing identity. Keeping a
/// durable copy would be risk with no benefit.
struct TailnetConfiguration: Codable, Equatable, Sendable {
    /// hsproxy's hostname and port, and the name its certificate is verified
    /// against on the bootstrap path.
    let headscaleHost: String
    let headscalePort: UInt16

    /// MagicDNS name and base domain gitd answers on, so the server URL and the
    /// in-tailnet control address can both be rebuilt without reopening the
    /// pairing record.
    let gitdTailnetName: String
    let baseDomain: String

    /// The port gitd serves Git and LFS on inside the tailnet.
    ///
    /// Pinned rather than delivered in the pairing record because it is a
    /// property of the gitd build, and a device only ever talks to a gitd from
    /// the same release. It must stay in step with the ports the headscale
    /// policy opens, since a device dialling anything else is refused by the
    /// tailnet before gitd ever sees it.
    static let gitdPort: UInt16 = 8443

    /// The URL gitd is reachable at once the device is on the tailnet.
    ///
    /// Plain `https` because that is the form the rest of the app stores and
    /// `MTLSTransport.convertToMTLSScheme` expects; the LAN path stores the
    /// same shape from its QR code.
    ///
    /// The port is explicit because gitd's tailnet listener is not on 443, and
    /// an implied 443 would leave every request hanging against a port nothing
    /// is bound to.
    var gitdURL: String {
        "https://\(gitdTailnetName).\(baseDomain):\(Self.gitdPort)"
    }
}

/// Persists the tailnet configuration across launches.
///
/// UserDefaults rather than the keychain: nothing here is a credential, and
/// putting it in the keychain would mean it survived an uninstall, leaving a
/// reinstalled app trying to rejoin a tailnet whose node state is gone.
final class TailnetConfigurationManager {
    static let shared = TailnetConfigurationManager()

    private static let storageKey = "replycant.tailnet.config"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns nil rather than throwing on anything unexpected, so a corrupted
    /// entry degrades to "not on a tailnet" instead of blocking startup.
    func load() -> TailnetConfiguration? {
        guard let raw = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(TailnetConfiguration.self, from: raw)
    }

    func save(_ configuration: TailnetConfiguration) {
        guard let encoded = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Derives what to persist from a pairing record.
    ///
    /// The pre-auth key in the record is deliberately dropped here rather than
    /// at the call site, so there is one place that decides what outlives the
    /// pairing attempt.
    static func from(payload: PairingRecord.Payload) throws -> TailnetConfiguration {
        let trimmed = payload.headscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host,
              !host.isEmpty else {
            throw PairingRecord.PairingError.malformedHeadscaleURL
        }
        // The URL form only exists because that is how headscale advertises
        // itself; the shim speaks TLS straight to hsproxy and needs a port.
        let port = components.port ?? (components.scheme == "http" ? 80 : 443)

        return TailnetConfiguration(
            headscaleHost: host,
            headscalePort: UInt16(port),
            gitdTailnetName: payload.gitdTailnetName,
            baseDomain: payload.baseDomain
        )
    }
}
