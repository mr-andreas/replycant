import Foundation
import Testing
import LibGit2

/// Covers the evidence the connection banner trusts.
///
/// The tailnet node stays Running with no network at all, so the banner
/// has to follow path changes and the outcome of real requests instead.
@Suite(.serialized)
struct ServerReachabilityTests {
    // A request that dies before any HTTP response is how a phone with a
    // network, but no path to the server, is told apart from one that
    // reached gitd and got an error back.
    @Test func transportFailuresMarkTheServerUnreachable() {
        let reachability = ServerReachability()

        reachability.recordFailure(URLError(.timedOut))
        #expect(reachability.isReachable == false)

        reachability.recordResponse()
        reachability.recordFailure(URLError(.cannotConnectToHost))
        #expect(reachability.isReachable == false)
    }

    // A stopped library server fails the task as a bad URL, with no HTTP
    // response. That is the same evidence as a timeout: the server was
    // not reached. The banner posts once, and a later response clears it.
    @Test func aBadURLMarksTheServerUnreachable() {
        let notifications = NotificationCenter()
        let reachability = ServerReachability(notifications: notifications)
        var posts = 0
        let token = notifications.addObserver(
            forName: .serverReachabilityDidChange,
            object: nil,
            queue: nil
        ) { _ in
            posts += 1
        }
        defer { notifications.removeObserver(token) }

        reachability.recordFailure(URLError(.badURL))

        #expect(reachability.isReachable == false)
        #expect(posts == 1)

        reachability.recordResponse()

        #expect(reachability.isReachable == true)
        #expect(posts == 2)
    }

    // The screen shows one sentence for any failure that never reached
    // the library. A different problem keeps the caller's own wording.
    @Test func presentedReplacesOnlyAFailureThatNeverReachedTheServer() {
        let sentence = "The library server cannot be reached."
        #expect(ServerReachability.presented(URLError(.badURL)).localizedDescription == sentence)
        #expect(ServerReachability.presented(URLError(.timedOut)).localizedDescription == sentence)

        let other = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]
        )
        #expect(ServerReachability.presented(other).localizedDescription == "Photo library access denied")
    }

    // Cancelling a transfer is the app stopping it. Treating that as a
    // lost server would flash the banner every time a photo is dismissed.
    @Test func aCancelledRequestIsNotEvidence() {
        let reachability = ServerReachability()

        reachability.recordFailure(URLError(.cancelled))

        #expect(reachability.isReachable == true)
    }

    // Any HTTP status means the server answered. A 404 is a missing
    // object, not a phone that cannot reach the library.
    @Test func aResponseRestoresReachable() {
        let reachability = ServerReachability()
        reachability.recordFailure(URLError(.timedOut))

        reachability.recordResponse()

        #expect(reachability.isReachable == true)
    }

    // Wi-Fi off with no SIM is a path the system reports immediately,
    // before any request has to time out. A path coming back is only a
    // guess: the next request corrects it if the server is still gone.
    @Test func anUnsatisfiedPathMarksTheServerUnreachable() {
        let reachability = ServerReachability()

        reachability.recordPath(satisfied: false)
        #expect(reachability.isReachable == false)

        reachability.recordPath(satisfied: true)
        #expect(reachability.isReachable == true)
    }

    // The banner refreshes on this notification. Repeating it when
    // nothing changed would re-check the join for every request.
    @Test func postsOnlyWhenReachabilityChanges() {
        let notifications = NotificationCenter()
        let reachability = ServerReachability(notifications: notifications)
        var posts = 0
        let token = notifications.addObserver(
            forName: .serverReachabilityDidChange,
            object: nil,
            queue: nil
        ) { _ in
            posts += 1
        }
        defer { notifications.removeObserver(token) }

        reachability.recordResponse()
        reachability.recordFailure(URLError(.cancelled))
        #expect(posts == 0)

        reachability.recordFailure(URLError(.timedOut))
        reachability.recordFailure(URLError(.cannotConnectToHost))
        #expect(posts == 1)
        #expect(reachability.isReachable == false)

        reachability.recordResponse()
        #expect(posts == 2)
        #expect(reachability.isReachable == true)
    }
}
