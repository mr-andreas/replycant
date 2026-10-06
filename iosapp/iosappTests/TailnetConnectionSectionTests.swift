import Foundation
import LibGit2
import Testing
@testable import iosapp

// Covers what Settings decides to show for the Connection section.
//
// The section used to load itself from an empty List child, which never
// appeared, so a joined device looked unpaired. These cases are the only
// thing that keeps that from happening again: hide until the load
// finishes, hide unpaired devices, and still show something when the node is
// configured but status cannot be read.
struct TailnetConnectionSectionTests {
    private static func report() throws -> TailnetStatusReport {
        try TailnetStatusReport.decode(
            Data(#"{"BackendState":"Running"}"#.utf8),
            controlRoute: .relay
        )
    }

    // An unpaired device must not flash a Connection section while Settings
    // asks whether there is a tailnet at all.
    @Test func hidesUntilTheLoadFinishes() {
        #expect(
            TailnetConnectionSection.presentation(
                hasLoaded: false,
                isConfigured: false,
                report: nil
            ) == .hidden
        )
        #expect(
            TailnetConnectionSection.presentation(
                hasLoaded: false,
                isConfigured: true,
                report: nil
            ) == .hidden
        )
    }

    // A device with no tailnet configuration has nothing to describe. A
    // section reporting a broken connection would send the user chasing a
    // problem they do not have.
    @Test func hidesAnUnpairedDeviceAfterLoad() {
        #expect(
            TailnetConnectionSection.presentation(
                hasLoaded: true,
                isConfigured: false,
                report: nil
            ) == .hidden
        )
    }

    @Test func showsALiveReport() throws {
        let report = try Self.report()

        #expect(
            TailnetConnectionSection.presentation(
                hasLoaded: true,
                isConfigured: true,
                report: report
            ) == .report(report)
        )
    }

    // A configured device whose node is up but status failed is not
    // unpaired. Hiding the section is what made a successful join look like
    // the feature was missing.
    @Test func showsUnavailableWhenConfiguredButStatusIsMissing() {
        #expect(
            TailnetConnectionSection.presentation(
                hasLoaded: true,
                isConfigured: true,
                report: nil
            ) == .unavailable
        )
    }

    // Server path must not reuse Control path's "Hosted relay" wording.
    // That hop is Replycant's tunnel to headscale; this one is Tailscale
    // DERP to gitd, and the region is what makes them distinguishable.
    @Test func namesTheServerPathWithoutCallingItTheHostedRelay() {
        #expect(TailnetConnectionSection.describe(.direct) == "Direct")
        #expect(TailnetConnectionSection.describe(.relay(region: "hel")) == "Relay (hel)")
        #expect(TailnetConnectionSection.describe(.offline) == "Offline")
    }
}
