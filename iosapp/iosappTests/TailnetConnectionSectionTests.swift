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
            Data(#"{"BackendState":"Running"}"#.utf8)
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

    // The Settings row and the Connection page share one wording, so a
    // device that has not produced a report cannot look healthy on one
    // surface and broken on the other.
    @Test func namesAMissingReportUnavailable() {
        let status = TailnetConnectionSection.status(of: nil)
        #expect(status.text == "Unavailable")
        #expect(status.isHealthy == false)
    }

    @Test func namesARunningNodeConnected() throws {
        let status = TailnetConnectionSection.status(of: try Self.report())
        #expect(status.text == "Connected")
        #expect(status.isHealthy == true)
    }

    // NeedsLogin is the state a user has to quote when asking for help,
    // so the row must show the backend name instead of a generic failure.
    @Test func namesALoggedOutNodeByItsBackendState() throws {
        let report = try TailnetStatusReport.decode(
            Data(#"{"BackendState":"NeedsLogin"}"#.utf8)
        )
        let status = TailnetConnectionSection.status(of: report)
        #expect(status.text == "NeedsLogin")
        #expect(status.isHealthy == false)
    }

    // The region is what makes a DERP hop distinct from a direct connection.
    @Test func namesTheServerPathWithoutCallingItTheHostedRelay() {
        #expect(TailnetConnectionSection.describe(.direct) == "Direct")
        #expect(TailnetConnectionSection.describe(.relay(region: "hel")) == "Relay (hel)")
        #expect(TailnetConnectionSection.describe(.offline) == "Offline")
    }
}
