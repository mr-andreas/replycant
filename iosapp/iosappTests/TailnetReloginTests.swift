import Foundation
import Testing
@testable import LibGit2

// Covers how the device gets back onto the tailnet after headscale forgot it.
//
// headscale's database is a cache of pubkeys/ in the repository. It can be
// wiped and rebuilt, and gitd drops every device node whenever a key leaves
// pubkeys/. A device that is still authorized has to notice and rejoin with a
// key it mints itself; nobody should have to re-pair it. A real node cannot
// run in a unit test, so these pin down each decision the rejoin depends on.
struct TailnetReloginTests {
    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:1/replycant/preauthkey")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    // hsproxy answers the key request itself with a small JSON object. The
    // key inside is what the node logs in with.
    @Test func aGrantedKeyIsDecoded() throws {
        let key = try HeadscaleControlShim.decodePreauthKey(
            data: Data(#"{"preauth_key":"hskey-auth-minted"}"#.utf8),
            response: Self.response(status: 200)
        )
        #expect(key == "hskey-auth-minted")
    }

    // hsproxy refuses keys during the empty-repository bootstrap window and to
    // revoked devices. That must surface as an error naming the status, not as
    // an empty key the node would then fail to log in with.
    @Test func aRefusalReportsItsStatus() {
        #expect(throws: HeadscaleControlShim.ShimError.keyRefused(403)) {
            try HeadscaleControlShim.decodePreauthKey(
                data: Data(),
                response: Self.response(status: 403)
            )
        }
    }

    // A 200 without a usable key is not hsproxy. Logging in with an empty key
    // would leave the node waiting for an interactive login forever.
    @Test func aResponseWithoutAKeyIsRejected() {
        #expect(throws: HeadscaleControlShim.ShimError.malformedKeyResponse) {
            try HeadscaleControlShim.decodePreauthKey(
                data: Data(#"{"preauth_key":"  "}"#.utf8),
                response: Self.response(status: 200)
            )
        }
    }

    // A running node that headscale has forgotten never changes state: its map
    // polls fail with 404 and it keeps reporting Running. That log line is the
    // only signal, so it has to be caught.
    @Test func aForgottenNodeIsNoticedInTheLog() {
        let signal = TailnetForgottenNodeSignal()
        signal.observe("tsnet: control: [v1] PollNetMap: initial fetch failed 404: node not found")
        #expect(signal.consume())
        #expect(!signal.consume(), "the signal is consumed once acted on")
    }

    // Ordinary network trouble also produces control errors. Only the control
    // plane saying it does not know the node justifies spending a key.
    @Test func unrelatedLogLinesAreIgnored() {
        let signal = TailnetForgottenNodeSignal()
        signal.observe("tsnet: control: [v1] PollNetMap: dial tcp: connection refused")
        signal.observe("tsnet: magicsock: endpoints changed")
        #expect(!signal.consume())
    }

    private static func stateDirectory(_ state: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailnet-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let state {
            try Data(state.utf8).write(to: directory.appendingPathComponent("tailscaled.state"))
        }
        return directory
    }

    // A node that has never logged in must be started with a key. Started
    // without one it sits in NeedsLogin inside tailscale_up, which libtailscale
    // can neither cancel nor close, so the join would hang for good.
    @Test func aFreshStateDirectoryIsAFirstLogin() throws {
        #expect(TailnetManager.isFirstLogin(stateDirectory: try Self.stateDirectory(nil)))
    }

    // An earlier attempt that never logged in leaves a machine key behind.
    // That is still a first login; treating it as a rejoin is what made a
    // retried join hang the same way.
    @Test func aMachineKeyWithoutAProfileIsAFirstLogin() throws {
        let directory = try Self.stateDirectory(#"{"_machinekey":"AAAA"}"#)
        #expect(TailnetManager.isFirstLogin(stateDirectory: directory))
    }

    // A node that has logged in rejoins on its own, and must not cost a key
    // on every launch.
    @Test func aLoggedInNodeIsNotAFirstLogin() throws {
        let directory = try Self.stateDirectory(
            #"{"_machinekey":"AAAA","_current-profile":"BBBB","_profiles":"CCCC"}"#
        )
        #expect(!TailnetManager.isFirstLogin(stateDirectory: directory))
    }

    // NeedsLogin is read from the node's own status, which is the structured
    // signal for a node that started with state headscale no longer has.
    @Test func needsLoginIsReadFromTheStatus() throws {
        let report = try TailnetStatusReport.decode(
            Data(#"{"BackendState":"NeedsLogin"}"#.utf8),
            controlRoute: nil
        )
        #expect(report.needsLogin)

        let running = try TailnetStatusReport.decode(
            Data(#"{"BackendState":"Running"}"#.utf8),
            controlRoute: nil
        )
        #expect(!running.needsLogin)
    }
}
