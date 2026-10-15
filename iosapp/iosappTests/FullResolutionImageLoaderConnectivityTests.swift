import Foundation
import LibGit2
import Testing
import Combine
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

    // The full-screen viewer retries by calling loadOriginal again. A
    // failure has to leave the loader idle with an error, and the next
    // call has to actually start instead of being swallowed.
    @Test func failedLoadStaysIdleSoItCanBeRetried() async {
        let manager = TimelineManager(notificationCenter: NotificationCenter())
        let loader = FullResolutionImageLoader(timelineManager: manager)
        var starts = 0
        let cancellable = loader.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { isLoading in
                if isLoading { starts += 1 }
            }

        loader.loadOriginal(for: makePhotoWithoutRepository(), isVideo: false)
        await waitUntilSettled(loader)
        await waitUntil { starts == 1 }
        #expect(loader.errorMessage != nil)
        #expect(loader.isLoading == false)
        #expect(starts == 1)

        loader.loadOriginal(for: makePhotoWithoutRepository(), isVideo: false)
        await waitUntilSettled(loader)
        await waitUntil { starts == 2 }
        #expect(loader.errorMessage != nil)
        #expect(loader.isLoading == false)
        #expect(starts == 2)
        _ = cancellable
    }
}

// A photo with no local copy and no repository. Loading it fails before
// any network call, which is the state the Retry button has to recover from.
private func makePhotoWithoutRepository() -> TimelineItem {
    let manifest = OriginalManifest(
        id: "photo-1",
        localID: nil,
        sha256: "sha-photo-1",
        path: "file-photo-1",
        filesize: 1024,
        name: "photo-1",
        deviceSpace: "device-space-1",
        mediaType: "photo",
        width: 100,
        height: 100,
        modifiedAt: nil,
        duration: nil,
        mimeType: "image/jpeg",
        location: nil,
        isFavorite: false,
        isHidden: false,
        burstIdentifier: nil,
        createdAt: Date(),
        takenAt: Date(),
        clientCTime: nil,
        guessedTakenAt: Date()
    )
    return TimelineItem(original: manifest)
}

@MainActor
private func waitUntilSettled(_ loader: FullResolutionImageLoader) async {
    for _ in 0..<120 {
        if loader.errorMessage != nil && !loader.isLoading {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<120 {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
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
