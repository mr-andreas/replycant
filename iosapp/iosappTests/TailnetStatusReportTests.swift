import Foundation
import Testing
@testable import LibGit2

// Covers the projection the Settings connection section renders.
//
// A device that cannot reach the server gives one symptom either way, so this
// mapping is the only thing that lets a user tell "not on the tailnet" from
// "on the tailnet but the server is down". Its input is tailscale's local API
// JSON, which nothing in this repo controls, so the field names are pinned
// here.
struct TailnetStatusReportTests {
    // Shaped like what tailscale's local API actually returns, including the
    // capitalised keys and the "Self" key that Swift needs backticks for.
    private static func statusJSON(
        backendState: String = "Running",
        extra: String = "",
        gitdPeer: String? = """
              "ID": "n1",
              "HostName": "gitd",
              "DNSName": "gitd.replycant.internal.",
              "Online": true,
              "CurAddr": "192.0.2.10:41641",
              "ExitNode": false,
              "ExitNodeOption": false
        """
    ) -> Data {
        let gitdEntry = gitdPeer.map { """
            "nodekey:aaa": {
        \($0)
            },
        """ } ?? ""
        return Data("""
        {
          "Version": "1.102.3",
          "BackendState": "\(backendState)",
          "AuthURL": "",
          "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
          "Self": {
            "ID": "nself",
            "HostName": "iphone",
            "DNSName": "iphone.replycant.internal.",
            "Relay": "fra",
            "Online": true,
            "ExitNode": false,
            "ExitNodeOption": false
          },
          "Peer": {
            \(gitdEntry)
            "nodekey:bbb": {
              "ID": "n2",
              "HostName": "desktop",
              "DNSName": "desktop.replycant.internal.",
              "Online": false,
              "ExitNode": false,
              "ExitNodeOption": false
            }
          }\(extra)
        }
        """.utf8)
    }

    @Test func readsWhatTheSettingsScreenShows() throws {
        let report = try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: .tailnet)

        #expect(report.isConnected)
        #expect(report.backendState == "Running")
        #expect(report.tailnetIPs == ["100.64.0.2", "fd7a:115c:a1e0::2"])
        #expect(report.derpHome == "fra")
        #expect(report.serverPath == .direct)
        #expect(report.peers == 2)
        #expect(report.peersOnline == 1)
    }

    // Control path and server path are different hops. A device on the hosted
    // relay can still have a direct WireGuard path to gitd, and the Settings
    // row is the only place that distinction is visible.
    @Test func reportsADirectPathWhenGitdHasACurrentAddress() throws {
        #expect(try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: .relay)
            .serverPath == .direct)
    }

    // Empty CurAddr with a Relay region is Tailscale's DERP hop, not
    // Replycant's hosted tunnel. Showing the region is what keeps "hel" from
    // being read as the control-path hosted relay.
    @Test func reportsARelayPathWhenGitdHasNoCurrentAddress() throws {
        let json = Self.statusJSON(gitdPeer: """
              "ID": "n1",
              "HostName": "gitd",
              "DNSName": "gitd.replycant.internal.",
              "Online": true,
              "Relay": "hel"
        """)

        #expect(try TailnetStatusReport.decode(json, controlRoute: .tailnet)
            .serverPath == .relay(region: "hel"))
    }

    // gitd being present but offline is the case the panel exists for: the
    // device is on the tailnet and the server is down.
    @Test func reportsOfflineWhenGitdIsNotOnline() throws {
        let json = Self.statusJSON(gitdPeer: """
              "ID": "n1",
              "HostName": "gitd",
              "DNSName": "gitd.replycant.internal.",
              "Online": false,
              "Relay": "hel"
        """)

        #expect(try TailnetStatusReport.decode(json, controlRoute: .tailnet)
            .serverPath == .offline)
    }

    // Status is read before peers appear. Claiming a path to a server that
    // has not been seen would be a guess.
    @Test func hidesTheServerPathWhenGitdIsMissing() throws {
        #expect(try TailnetStatusReport.decode(
            Self.statusJSON(gitdPeer: nil),
            controlRoute: .tailnet
        ).serverPath == nil)
    }

    // MagicDNS is the pinned name, but some status payloads only carry the
    // short hostname. Either handle has to find gitd, or a LAN device would
    // hide a path it actually has.
    @Test func findsGitdByHostnameWhenDNSNameIsAbsent() throws {
        let json = Self.statusJSON(gitdPeer: """
              "ID": "n1",
              "HostName": "gitd",
              "Online": true,
              "CurAddr": "192.0.2.10:41641"
        """)

        #expect(try TailnetStatusReport.decode(json, controlRoute: .tailnet)
            .serverPath == .direct)
    }

    // Only Running means traffic can flow, and a section claiming a connection
    // that does not exist is worse than one saying nothing.
    @Test func onlyRunningCountsAsConnected() throws {
        for state in ["Starting", "Stopped", "NeedsLogin", "NoState"] {
            let report = try TailnetStatusReport.decode(
                Self.statusJSON(backendState: state),
                controlRoute: nil
            )
            #expect(report.isConnected == false, "\(state) must not read as connected")
            #expect(report.backendState == state)
        }
    }

    // The shim owns this choice, so it cannot come from the node's status. A
    // device permanently on the relay has no other visible symptom.
    @Test func carriesTheControlPathTheShimUsed() throws {
        #expect(try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: .relay)
            .controlRoute == .relay)
        #expect(try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: .tailnet)
            .controlRoute == .tailnet)
    }

    // Before the first control session there is no path to report, and
    // claiming one would be a guess.
    @Test func reportsNoControlPathBeforeAnyControlSession() throws {
        #expect(try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: nil)
            .controlRoute == nil)
    }

    // A node can be Running and still unable to carry traffic, which would
    // otherwise look like a healthy tailnet and a broken server.
    @Test func surfacesHealthWarnings() throws {
        let json = Self.statusJSON(extra: """
        ,
          "Health": ["DERP region fra is unreachable"]
        """)

        let report = try TailnetStatusReport.decode(json, controlRoute: .tailnet)
        #expect(report.health == ["DERP region fra is unreachable"])
    }

    // Status is read from the moment the node starts, long before it has
    // addresses, peers, or a relay region. A settings screen that threw during
    // startup would be worse than one showing an incomplete picture.
    @Test func toleratesAPartiallyStartedNode() throws {
        let json = Data(#"{"BackendState":"Starting","AuthURL":"","Version":"1.102.3"}"#.utf8)

        let report = try TailnetStatusReport.decode(json, controlRoute: nil)
        #expect(report.backendState == "Starting")
        #expect(report.tailnetIPs.isEmpty)
        #expect(report.derpHome == "")
        #expect(report.serverPath == nil)
        #expect(report.peers == 0)
        #expect(report.health.isEmpty)
    }

    // The log line is what gets captured next to a slow LFS transfer.
    // It has to name both hops the way Settings does, and keep the gitd
    // endpoint Settings discards after deciding the path is direct.
    @Test func summarizesADirectPathWithTheGitdEndpoint() throws {
        let report = try TailnetStatusReport.decode(Self.statusJSON(), controlRoute: .relay)

        #expect(report.gitdAddress == "192.0.2.10:41641")
        #expect(report.logLines == [
            "state=Running address=100.64.0.2 control=Hosted relay server=Direct gitd=192.0.2.10:41641 derp=fra peers=1/2"
        ])
    }

    // A relayed gitd has no current address. Printing one would make a
    // DERP hop look like a LAN path.
    @Test func summarizesARelayPathWithoutAnEndpoint() throws {
        let json = Self.statusJSON(gitdPeer: """
              "ID": "n1",
              "HostName": "gitd",
              "DNSName": "gitd.replycant.internal.",
              "Online": true,
              "Relay": "hel"
        """)

        let report = try TailnetStatusReport.decode(json, controlRoute: .tailnet)
        #expect(report.gitdAddress == nil)
        #expect(report.logLines == [
            "state=Running address=100.64.0.2 control=Direct server=Relay (hel) derp=fra peers=1/2"
        ])
    }

    // Offline is the case a log has to make obvious: this device is up
    // and the server is not, which is not the same as a slow direct path.
    @Test func summarizesAnOfflineServer() throws {
        let json = Self.statusJSON(gitdPeer: """
              "ID": "n1",
              "HostName": "gitd",
              "DNSName": "gitd.replycant.internal.",
              "Online": false,
              "Relay": "hel"
        """)

        #expect(try TailnetStatusReport.decode(json, controlRoute: .tailnet).logLines == [
            "state=Running address=100.64.0.2 control=Direct server=Offline derp=fra peers=0/2"
        ])
    }

    // Health warnings follow the summary so a node that is Running and
    // still unable to carry traffic is visible in the same capture.
    @Test func followsTheSummaryWithHealthWarnings() throws {
        let json = Self.statusJSON(extra: """
        ,
          "Health": ["DERP region fra is unreachable"]
        """)

        #expect(try TailnetStatusReport.decode(json, controlRoute: .tailnet).logLines == [
            "state=Running address=100.64.0.2 control=Direct server=Direct gitd=192.0.2.10:41641 derp=fra peers=1/2",
            "DERP region fra is unreachable"
        ])
    }

    // The local API is reached over loopback and cannot be spoofed, but a
    // version change could still alter the payload, and that must fail loudly
    // rather than render as a disconnected tailnet.
    @Test func rejectsAPayloadItCannotParse() {
        #expect(throws: (any Error).self) {
            try TailnetStatusReport.decode(Data("not json".utf8), controlRoute: nil)
        }
    }
}
