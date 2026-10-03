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

    // A node without a key that headscale does not know sits in NeedsLogin and
    // never finishes coming up. Winning that race is what triggers minting.
    @Test func aNodeThatNeedsLoginIsAbandonedForAFreshKey() async throws {
        let abandoned = Flag()
        let outcome = try await TailnetManager.upOrNeedsLogin(
            up: {
                // Returns only once abandoned, like tailscale_up after close.
                while !(await abandoned.isSet) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CancellationError()
            },
            needsLogin: { true },
            abandon: { await abandoned.set() },
            pollInterval: .milliseconds(10)
        )

        #expect(outcome == .needsLogin)
        #expect(await abandoned.isSet, "the stuck node must be closed so up() returns")
    }

    // A node headscale still knows comes up on its own, and must not cost a key.
    @Test func aNodeThatComesUpIsKept() async throws {
        let abandoned = Flag()
        let outcome = try await TailnetManager.upOrNeedsLogin(
            up: {},
            needsLogin: { false },
            abandon: { await abandoned.set() },
            pollInterval: .milliseconds(10)
        )

        #expect(outcome == .running)
        #expect(!(await abandoned.isSet))
    }

    // A genuine failure to come up is not a login problem and must reach the
    // caller rather than being papered over with a key.
    @Test func aFailedUpIsReported() async {
        struct Broken: Error {}
        await #expect(throws: Broken.self) {
            _ = try await TailnetManager.upOrNeedsLogin(
                up: { throw Broken() },
                needsLogin: { false },
                abandon: {},
                pollInterval: .milliseconds(10)
            )
        }
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

// A one-way latch shared between the test and the closures it hands out.
private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
