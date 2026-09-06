import Foundation

/// How this device is connected to its deployment's tailnet.
///
/// Before this existed, a device that could not reach the server gave one
/// symptom - a failed sync - whether it was off the tailnet, on the tailnet but
/// unable to route, or on the tailnet with the server down. The user's only
/// recourse was to re-pair. Every field here exists to make those cases
/// distinguishable.
public struct TailnetStatusReport: Sendable, Equatable {
    /// One of tailscale's backend states. Only `Running` means traffic can
    /// flow; anything else is worth showing verbatim, because the state names
    /// are the only handle a user has when asking for help.
    public let backendState: String

    public let tailnetIPs: [String]

    /// The DERP region carrying this node's traffic, empty before the node
    /// picks one.
    public let derpHome: String

    /// Which path the shim's most recent control session took, or nil before
    /// any control session happened. Not part of tailscale's status because the
    /// shim owns the choice, and a device stuck on the hosted relay has no
    /// other visible symptom.
    public let controlRoute: HeadscaleControlShim.Route?

    public let peers: Int
    public let peersOnline: Int

    /// tailscale's own warnings. A node can be `Running` and still unable to
    /// carry traffic, which would otherwise look like a healthy tailnet and a
    /// broken server.
    public let health: [String]

    public var isConnected: Bool { backendState == Self.runningState }

    static let runningState = "Running"

    /// What the local API reports, reduced to the fields that matter.
    ///
    /// Decoded from the raw JSON rather than through TailscaleKit's own status
    /// type so this stays testable against a recorded payload and so the app
    /// layer does not need to import TailscaleKit to read a status.
    ///
    /// Keys are capitalised because that is what tailscale's local API emits.
    private struct Wire: Decodable {
        struct Peer: Decodable {
            let Online: Bool?
            let Relay: String?
        }

        let BackendState: String?
        let TailscaleIPs: [String]?
        let Health: [String]?
        let `Self`: Peer?
        let Peer: [String: Peer]?
    }

    /// Projects a raw local-API status onto what the app shows.
    ///
    /// Tolerant of missing fields because status is read from the moment the
    /// node starts, long before it has addresses, peers, or a relay region,
    /// and a settings screen that threw during startup would be worse than one
    /// reporting an incomplete picture.
    public static func decode(
        _ data: Data,
        controlRoute: HeadscaleControlShim.Route?
    ) throws -> TailnetStatusReport {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let peers = wire.Peer ?? [:]

        return TailnetStatusReport(
            backendState: wire.BackendState ?? "Unknown",
            tailnetIPs: wire.TailscaleIPs ?? [],
            derpHome: wire.`Self`?.Relay ?? "",
            controlRoute: controlRoute,
            peers: peers.count,
            peersOnline: peers.values.filter { $0.Online == true }.count,
            health: wire.Health ?? []
        )
    }
}
