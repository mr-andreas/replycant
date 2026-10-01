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

    /// How Git and LFS currently reach gitd, or nil before that peer appears.
    ///
    /// Distinct from `controlRoute`: that hop is the shim's path to headscale,
    /// and a device on the hosted relay can still have a direct WireGuard
    /// path to the server. This is the row that makes those distinguishable.
    public let serverPath: ServerPath?

    /// The address Tailscale is currently using to reach gitd.
    ///
    /// Settings only keeps the direct-versus-relay classification. The
    /// endpoint is what shows whether "Direct" is the LAN or some other hop.
    public let gitdAddress: String?

    /// How this device reaches gitd over the tailnet.
    ///
    /// Worth its own type so Settings can name Tailscale DERP without
    /// reusing the control path's "Hosted relay" wording.
    public enum ServerPath: Equatable, Sendable {
        case direct
        case relay(region: String)
        case offline
    }

    public let peers: Int
    public let peersOnline: Int

    /// tailscale's own warnings. A node can be `Running` and still unable to
    /// carry traffic, which would otherwise look like a healthy tailnet and a
    /// broken server.
    public let health: [String]

    public var isConnected: Bool { backendState == Self.runningState }

    /// One status line, then any health warnings.
    ///
    /// Uses the same words as Settings so a log captured during a slow
    /// transfer shows direct versus relay without opening that screen.
    public var logLines: [String] {
        var parts = ["state=\(backendState)"]
        if let address = tailnetIPs.first {
            parts.append("address=\(address)")
        }
        parts.append("control=\(Self.controlLabel(controlRoute))")
        parts.append("server=\(Self.serverLabel(serverPath))")
        if let gitdAddress {
            parts.append("gitd=\(gitdAddress)")
        }
        if !derpHome.isEmpty {
            parts.append("derp=\(derpHome)")
        }
        parts.append("peers=\(peersOnline)/\(peers)")
        return [parts.joined(separator: " ")] + health
    }

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
            let HostName: String?
            let DNSName: String?
            let Online: Bool?
            let CurAddr: String?
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
        let gitd = peers.values.first(where: isGitd)

        return TailnetStatusReport(
            backendState: wire.BackendState ?? "Unknown",
            tailnetIPs: wire.TailscaleIPs ?? [],
            derpHome: wire.`Self`?.Relay ?? "",
            controlRoute: controlRoute,
            serverPath: gitd.flatMap(classify),
            gitdAddress: Self.endpoint(of: gitd),
            peers: peers.count,
            peersOnline: peers.values.filter { $0.Online == true }.count,
            health: wire.Health ?? []
        )
    }

    /// Names the control hop the way Settings does.
    private static func controlLabel(_ route: HeadscaleControlShim.Route?) -> String {
        switch route {
        case .tailnet: return "Direct"
        case .relay: return "Hosted relay"
        case nil: return "Not yet used"
        }
    }

    /// Names the path to gitd the way Settings does.
    private static func serverLabel(_ path: ServerPath?) -> String {
        switch path {
        case .direct: return "Direct"
        case .relay(let region):
            return region.isEmpty ? "Relay" : "Relay (\(region))"
        case .offline: return "Offline"
        case nil: return "Not yet used"
        }
    }

    /// Keeps a non-empty CurAddr. An empty one means there is no endpoint.
    private static func endpoint(of peer: Wire.Peer?) -> String? {
        guard let address = peer?.CurAddr, !address.isEmpty else { return nil }
        return address
    }

    /// Matches the pinned MagicDNS name, or the short hostname when a
    /// payload omits DNSName. Either handle has to find gitd or a LAN
    /// device would hide a path it actually has.
    private static func isGitd(_ peer: Wire.Peer) -> Bool {
        if let dns = peer.DNSName {
            let name = dns.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if name.caseInsensitiveCompare(TailnetManager.gitdHost) == .orderedSame {
                return true
            }
        }
        return peer.HostName?.caseInsensitiveCompare("gitd") == .orderedSame
    }

    /// Follows Tailscale's own direct-vs-DERP rule without requiring an
    /// active session, because status is polled and sessions go idle
    /// between syncs.
    private static func classify(_ peer: Wire.Peer) -> ServerPath? {
        if peer.Online != true {
            return .offline
        }
        if let address = peer.CurAddr, !address.isEmpty {
            return .direct
        }
        if let region = peer.Relay, !region.isEmpty {
            return .relay(region: region)
        }
        return nil
    }
}
