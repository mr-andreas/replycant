import Foundation
import Testing
@testable import iosapp

/// Records each join attempt so a test can switch the outcome after the
/// banner has appeared.
private final class JoinScript: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error> = .success(())
    private var calls = 0
    private var timeout: Duration?

    func set(_ outcome: Result<Void, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var requestedTimeout: Duration? {
        lock.lock()
        defer { lock.unlock() }
        return timeout
    }

    func call(_ timeout: Duration) async throws {
        try nextOutcome(timeout).get()
    }

    /// Records one attempt. Kept synchronous so the lock is not taken
    /// from the async call the indicator awaits.
    private func nextOutcome(_ timeout: Duration) -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        self.timeout = timeout
        return outcome
    }
}

@MainActor
@Suite(.serialized)
struct TailnetJoinIndicatorTests {
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // A paired device that joins inside the window has nothing to warn
    // about. The banner is for a stall, not for the join itself.
    @Test func staysHiddenWhenTheJoinSucceeds() async {
        let script = JoinScript()
        let indicator = TailnetJoinIndicator(
            join: { try await script.call($0) },
            notifications: NotificationCenter()
        )
        let watch = Task { await indicator.watch() }
        defer { watch.cancel() }

        await waitUntil { script.callCount >= 1 }

        #expect(indicator.isUnreachable == false)
        #expect(script.requestedTimeout == TailnetJoinIndicator.stallTimeout)
    }

    // Five seconds without a node is the point the user should learn that
    // the library on screen is only what this device already has.
    @Test func showsTheBannerWhenTheJoinIsStillConnecting() async {
        let script = JoinScript()
        script.set(.failure(TailnetBootstrap.BootstrapError.stillConnecting))
        let indicator = TailnetJoinIndicator(
            join: { try await script.call($0) },
            notifications: NotificationCenter()
        )
        let watch = Task { await indicator.watch() }
        defer { watch.cancel() }

        await waitUntil { indicator.isUnreachable }

        #expect(indicator.isUnreachable == true)
    }

    // A refused join is the same situation for the user as one that is
    // still in progress: the library cannot be reached.
    @Test func showsTheBannerWhenTheJoinFails() async {
        let script = JoinScript()
        script.set(.failure(TailnetBootstrap.BootstrapError.missingDeviceIdentity))
        let indicator = TailnetJoinIndicator(
            join: { try await script.call($0) },
            notifications: NotificationCenter()
        )
        let watch = Task { await indicator.watch() }
        defer { watch.cancel() }

        await waitUntil { indicator.isUnreachable }

        #expect(indicator.isUnreachable == true)
    }

    // The join keeps running after the banner appears, and the membership
    // notification is how the banner learns it finished.
    @Test func hidesTheBannerWhenALaterJoinSucceeds() async {
        let script = JoinScript()
        script.set(.failure(TailnetBootstrap.BootstrapError.stillConnecting))
        let notifications = NotificationCenter()
        let indicator = TailnetJoinIndicator(
            join: { try await script.call($0) },
            notifications: notifications
        )
        let watch = Task { await indicator.watch() }
        defer { watch.cancel() }

        await waitUntil { indicator.isUnreachable }
        script.set(.success(()))
        notifications.post(name: .tailnetMembershipDidChange, object: nil)
        await waitUntil { script.callCount >= 2 && !indicator.isUnreachable }

        #expect(indicator.isUnreachable == false)
    }
}
