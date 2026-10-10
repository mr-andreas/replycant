import LibGit2
import SwiftUI

/// What Settings should put in the Connection slot.
///
/// Hidden until Settings has asked, so an unpaired device never flashes a
/// section that does not apply. After that: the live report, a plain
/// unavailable row when this device is on a tailnet but status could not
/// be read, or nothing when it has no tailnet configuration.
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

    /// How the path to gitd reads to a user.
    ///
    /// The region is what makes "hel" distinct from a direct connection.
    static func describe(_ path: TailnetStatusReport.ServerPath) -> String {
        switch path {
        case .direct: return "Direct"
        case .relay(let region):
            return region.isEmpty ? "Relay" : "Relay (\(region))"
        case .offline: return "Offline"
        }
    }

    /// What Settings puts under the connection rows. The device is on its
    /// own tailnet even though joining it still uses the hosted relay.
    static let footer = "Your device reaches this library over its own private network."
}
