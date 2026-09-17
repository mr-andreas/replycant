import LibGit2
import SwiftUI

/// What Settings should put in the Connection slot.
///
/// Hidden until Settings has asked, so a LAN device never flashes a
/// section that does not apply. After that: the live report, a plain
/// unavailable row when this device is on a tailnet but status could not
/// be read, or nothing on LAN.
enum TailnetConnectionPresentation: Equatable {
    case hidden
    case unavailable
    case report(TailnetStatusReport)
}

/// Rows for how this device reaches its library.
///
/// Settings owns the surrounding Section so List treats it as a real
/// section. This view used to wrap the Section and load from `.task` on
/// an empty Group; List skipped that child, so a joined device showed
/// nothing.
struct TailnetConnectionSection: View {
    let report: TailnetStatusReport

    var body: some View {
        LabeledContent("Status") {
            Text(report.isConnected ? "Connected" : report.backendState)
                .foregroundStyle(report.isConnected ? Color.green : Color.orange)
        }
        if let address = report.tailnetIPs.first {
            LabeledContent("Address", value: address)
        }
        LabeledContent("Control path", value: Self.describe(report.controlRoute))
        if let path = report.serverPath {
            LabeledContent("Server path", value: Self.describe(path))
        }
        if !report.derpHome.isEmpty {
            LabeledContent("Relay region", value: report.derpHome)
        }
        LabeledContent("Peers online", value: "\(report.peersOnline) of \(report.peers)")
        ForEach(report.health, id: \.self) { warning in
            Text(warning)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Decides whether Settings inserts the Connection section at all.
    ///
    /// The load lives on Settings, which always has on-screen List
    /// content, because a zero-height List child never runs `.task`.
    static func presentation(
        hasLoaded: Bool,
        isConfigured: Bool,
        report: TailnetStatusReport?
    ) -> TailnetConnectionPresentation {
        guard hasLoaded else { return .hidden }
        if let report {
            return .report(report)
        }
        return isConfigured ? .unavailable : .hidden
    }

    /// How the control path reads to a user.
    static func describe(_ route: HeadscaleControlShim.Route?) -> String {
        switch route {
        case .tailnet: return "Direct"
        case .relay: return "Hosted relay"
        case nil: return "Not yet used"
        }
    }

    /// How the path to gitd reads to a user.
    ///
    /// Named without "hosted" so Tailscale DERP is not mistaken for the
    /// control-plane tunnel. The region is what makes "hel" distinct.
    static func describe(_ path: TailnetStatusReport.ServerPath) -> String {
        switch path {
        case .direct: return "Direct"
        case .relay(let region):
            return region.isEmpty ? "Relay" : "Relay (\(region))"
        case .offline: return "Offline"
        }
    }

    /// Named explicitly because a device that never leaves the relay
    /// still works, but depends on hosted infrastructure for every
    /// session, and nothing else would show that.
    static func footer(for route: HeadscaleControlShim.Route?) -> String {
        route == .relay
            ? "Control traffic is going through Replycant's hosted relay instead of directly to your server."
            : "Your device reaches this library over its own private network."
    }
}
