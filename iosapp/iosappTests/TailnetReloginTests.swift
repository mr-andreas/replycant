import Foundation
import Testing
@testable import LibGit2

// Covers how the device gets back onto the tailnet after headscale forgot it.
//
// headscale's database is a cache of pubkeys/ in the repository. It can be
// wiped and rebuilt, and gitd expires every device node whenever a key leaves
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

    // tsnet's backend log arrives through a pipe in whatever chunks the OS
    // hands over. One read often holds several lines, and each has to reach
    // the signal and the app log on its own.
    @Test func aChunkWithSeveralLinesYieldsEachLine() {
        var lines = TailnetLogLines()
        #expect(lines.feed(Data("magicsock: up\ncontrol: mapRoutine\n".utf8)) == [
            "magicsock: up",
            "control: mapRoutine",
        ])
    }

    // A read can end mid-line, even mid-word. The 404 marker split across two
    // reads must still be seen once the line is complete, or a forgotten node
    // would go unnoticed depending on pipe timing.
    @Test func aLineSplitAcrossReadsIsReassembled() {
        var lines = TailnetLogLines()
        let signal = TailnetForgottenNodeSignal()

        let first = lines.feed(Data("control: [v1] PollNetMap: initial fetch fa".utf8))
        #expect(first.isEmpty)

        let second = lines.feed(Data("iled 404: node not found\n".utf8))
        #expect(second == ["control: [v1] PollNetMap: initial fetch failed 404: node not found"])
        second.forEach(signal.observe)
        #expect(signal.consume())
    }

    // Emitting a partial line would log half a message now and the rest as a
    // separate line later, and could match a marker against a fragment.
    @Test func aTrailingPartialLineIsHeldBack() {
        var lines = TailnetLogLines()
        #expect(lines.feed(Data("complete\npartial".utf8)) == ["complete"])
        #expect(lines.feed(Data(" line\n".utf8)) == ["partial line"])
    }

    // Tailscale tags structured lines with a NUL ("[v\0JSON]"). Left in, it
    // makes the shared app log look binary to grep and similar tools.
    @Test func nulBytesAreDropped() {
        var lines = TailnetLogLines()
        #expect(lines.feed(Data("control: [v\u{0}JSON]1{}\n".utf8)) == ["control: [vJSON]1{}"])
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

    // A node that starts from saved state headscale no longer has is logged in
    // again by restarting its backend with a key. The options must carry only
    // the key: any prefs sent along would overwrite the node's stored ones,
    // including its control URL and hostname.
    @Test func loginOptionsCarryOnlyTheKey() throws {
        let options = try TailnetManager.loginOptions(authKey: "hskey-auth-minted")
        let encoded = try JSONEncoder().encode(options)
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(fields?.count == 1)
        #expect(fields?["AuthKey"] as? String == "hskey-auth-minted")
    }

    // On a cold start from forgotten state the node waits in NeedsLogin inside
    // tailscale_up until something logs it in. The first time that is seen, a
    // key has to be minted, or the join never returns.
    @Test func needsLoginWithoutAnEarlierAttemptMints() {
        #expect(TailnetManager.shouldMint(needsLogin: true, lastAttempt: nil, now: Date()))
    }

    // tsnet passes through NeedsLogin while a key login is in flight. Minting
    // again then would waste a key and restart the backend mid-login.
    @Test func needsLoginWithinTheCooldownWaits() {
        let now = Date()
        let recent = now.addingTimeInterval(-(TailnetManager.reloginCooldown - 1))
        #expect(!TailnetManager.shouldMint(needsLogin: true, lastAttempt: recent, now: now))

        let old = now.addingTimeInterval(-(TailnetManager.reloginCooldown + 1))
        #expect(TailnetManager.shouldMint(needsLogin: true, lastAttempt: old, now: now))
    }

    // A node headscale still knows comes up on its own. Minting on every
    // launch would cost a key each time for nothing.
    @Test func aNodeThatDoesNotNeedLoginNeverMints() {
        #expect(!TailnetManager.shouldMint(needsLogin: false, lastAttempt: nil, now: Date()))
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

// Counts attempts for the retry helper without sharing mutable state across
// the test runner's tasks.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// Recovery rejoins the tailnet and then immediately talks to gitd. The first
// packets can be lost while the previous node's direct path is still cached,
// so the wait has to try again until one attempt works, and give up rather
// than hang when none ever does.
struct TailnetReachabilityRetryTests {
    @Test func retryUntilReturnsOnceAnAttemptSucceeds() async {
        let calls = AttemptCounter()
        let started = Date()
        let reached = await TailnetManager.retryUntil(
            timeout: .seconds(30),
            clock: { started },
            sleep: { _ in },
            attempt: { calls.next() >= 3 }
        )
        #expect(reached)
        #expect(calls.count == 3)
    }

    @Test func retryUntilGivesUpWhenTheTimeoutPasses() async {
        let calls = AttemptCounter()
        let started = Date()
        let clockReads = AttemptCounter()
        let reached = await TailnetManager.retryUntil(
            timeout: .milliseconds(500),
            clock: {
                clockReads.next() == 1 ? started : started.addingTimeInterval(1)
            },
            sleep: { _ in },
            attempt: {
                _ = calls.next()
                return false
            }
        )
        #expect(!reached)
        #expect(calls.count == 1)
    }
}
