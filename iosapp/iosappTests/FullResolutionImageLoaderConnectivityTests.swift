import Foundation
import LibGit2
import Testing
@testable import iosapp

// A fullscreen photo requested before the tailnet join finishes is
// refused before any bytes move. These tests cover the retry that
// waits for the join instead of leaving that photo on the spinner.
@MainActor
@Suite("FullResolutionImageLoader Connectivity Tests")
struct FullResolutionImageLoaderConnectivityTests {
    private struct OtherFailure: Error {}

    // The first attempt is the one issued before the node exists. The
    // second is the one that should paint the photo.
    @Test func retriesOnceTheWaitFinishes() async throws {
        var attempts = 0
        let value = try await FullResolutionImageLoader.loadWhenConnected(
            waitForNetwork: {}
        ) {
            attempts += 1
            if attempts == 1 {
                throw TailnetSessionRouter.RoutingError.notConnectedYet
            }
            return "photo"
        }

        #expect(value == "photo")
        #expect(attempts == 2)
    }

    // A transfer that failed for any other reason is done. Waiting
    // would hide that failure behind another spinner.
    @Test func otherFailuresDoNotWait() async {
        var waited = false
        await #expect(throws: OtherFailure.self) {
            try await FullResolutionImageLoader.loadWhenConnected(
                waitForNetwork: {
                    waited = true
                }
            ) {
                throw OtherFailure()
            }
        }
        #expect(waited == false)
    }

    // Swiping away while the photo is waiting must not start the
    // download once the tailnet comes up.
    @Test func cancellationDuringTheWaitIsNotRetried() async {
        let gate = WaitGate()
        var attempts = 0
        let task = Task {
            try await FullResolutionImageLoader.loadWhenConnected(
                waitForNetwork: { await gate.wait() }
            ) {
                attempts += 1
                throw TailnetSessionRouter.RoutingError.notConnectedYet
            }
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(attempts == 1)
    }
}

/// Holds the retry's network wait so a test can cancel it mid-wait.
private actor WaitGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        entered = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}
