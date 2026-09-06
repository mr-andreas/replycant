import LibGit2
import SwiftUI

/// Shows how this device reaches its library, in Settings.
///
/// A device that cannot reach the server gives one symptom - a failed sync -
/// whether it is off the tailnet, on the tailnet but unable to route, or on the
/// tailnet with the server down. This is what lets a user tell those apart
/// instead of re-pairing and hoping.
///
/// Renders nothing on LAN deployments: there is no tailnet to describe, and a
/// section reporting a broken connection would send the user chasing a problem
/// they do not have.
struct TailnetConnectionSection: View {
    /// Injected so previews and tests can show a state without a running node.
    let load: () async -> TailnetStatusReport?

    @State private var report: TailnetStatusReport?
    @State private var hasLoaded = false

    init(load: @escaping () async -> TailnetStatusReport? = { await TailnetBootstrap.shared.status() }) {
        self.load = load
    }

    var body: some View {
        Group {
            if let report {
                Section {
                    LabeledContent("Status") {
                        Text(report.isConnected ? "Connected" : report.backendState)
                            .foregroundStyle(report.isConnected ? Color.green : Color.orange)
                    }
                    if let address = report.tailnetIPs.first {
                        LabeledContent("Address", value: address)
                    }
                    LabeledContent("Control path", value: Self.describe(report.controlRoute))
                    if !report.derpHome.isEmpty {
                        LabeledContent("Relay region", value: report.derpHome)
                    }
                    LabeledContent("Peers online", value: "\(report.peersOnline) of \(report.peers)")
                    ForEach(report.health, id: \.self) { warning in
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    // Named explicitly because a device that never leaves the
                    // relay still works, but depends on hosted infrastructure
                    // for every session, and nothing else would show that.
                    Text(report.controlRoute == .relay
                        ? "Control traffic is going through Replycant's hosted relay instead of directly to your server."
                        : "Your device reaches this library over its own private network.")
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            report = await load()
        }
    }

    /// How the control path reads to a user.
    private static func describe(_ route: HeadscaleControlShim.Route?) -> String {
        switch route {
        case .tailnet: return "Direct"
        case .relay: return "Hosted relay"
        case nil: return "Not yet used"
        }
    }
}
