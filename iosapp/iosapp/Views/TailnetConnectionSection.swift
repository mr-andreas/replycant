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
/// The Connection page owns the surrounding Section. This view used to
/// wrap the Section and load from `.task` on an empty Group; List skipped
/// that child, so a joined device showed nothing.
struct TailnetConnectionSection: View {
    let report: TailnetStatusReport

    var body: some View {
        statusRow(for: report)
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

    /// Colors the status the same way the Settings row does, so opening
    /// Connection never changes what "healthy" means.
    private func statusRow(for report: TailnetStatusReport) -> some View {
        let status = Self.status(of: report)
        return LabeledContent("Status") {
            Text(status.text)
                .foregroundStyle(status.isHealthy ? Color.green : Color.orange)
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

    /// Wording shared by the Settings row and this page.
    ///
    /// A missing report is "Unavailable" rather than a blank row, because
    /// a configured device whose status could not be read is not unpaired.
    /// Only `Running` reads as healthy; every other backend state is shown
    /// verbatim so the user can quote it when asking for help.
    static func status(of report: TailnetStatusReport?) -> (text: String, isHealthy: Bool) {
        guard let report else { return ("Unavailable", false) }
        if report.isConnected { return ("Connected", true) }
        return (report.backendState, false)
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

/// The Connection page in Settings.
///
/// The list only has room for one status word. Address, path, relay,
/// peers, and health warnings live here so a failed sync can be told
/// apart from an unpaired device without crowding the settings list.
struct ConnectionSettingsView: View {
    let report: TailnetStatusReport?

    var body: some View {
        Form {
            Section {
                if let report {
                    TailnetConnectionSection(report: report)
                } else {
                    unavailableStatus
                }
            } footer: {
                Text(TailnetConnectionSection.footer)
            }
        }
        .navigationTitle("Connection")
    }

    /// A configured device whose status could not be read still has a
    /// page to open, and it must say Unavailable in the same words as
    /// the row that opened it.
    private var unavailableStatus: some View {
        let status = TailnetConnectionSection.status(of: nil)
        return LabeledContent("Status") {
            Text(status.text)
                .foregroundStyle(status.isHealthy ? Color.green : Color.orange)
        }
    }
}
