import Foundation
import Testing
@testable import iosapp

// The bar's position is pure data, so these checks do not need a clock
// or a view. They lock the two stretches a long pull actually measures.
struct LibrarySyncFractionTests {
    @Test func downloadFillsOnlyTheFirstHalf() {
        var fraction = LibrarySyncFraction()
        fraction.noteDownload(received: 1, total: 2)
        expectNear(fraction.value, 0.25)
        fraction.noteDownload(received: 2, total: 2)
        expectNear(fraction.value, 0.5)
        fraction.noteDownload(received: 9, total: 2)
        expectNear(fraction.value, 0.5)
    }

    @Test func downloadDoesNotMoveBackward() {
        var fraction = LibrarySyncFraction()
        fraction.noteDownload(received: 2, total: 2)
        fraction.noteDownload(received: 0, total: 2)
        expectNear(fraction.value, 0.5)
    }

    @Test func unknownTotalsStayIndeterminate() {
        var fraction = LibrarySyncFraction()
        fraction.noteDownload(received: 1, total: 0)
        fraction.noteApply(loaded: 1, total: 0)
        fraction.noteDownload(received: -1, total: 4)
        #expect(fraction.value == nil)

        fraction.noteDownload(received: 1, total: 4)
        expectNear(fraction.value, 0.125)
        fraction.noteDownload(received: 3, total: 0)
        expectNear(fraction.value, 0.125)
    }

    @Test func applyContinuesFromDownloadAndDoesNotMoveBackward() {
        var fraction = LibrarySyncFraction()
        fraction.noteDownload(received: 4, total: 4)
        fraction.noteApply(loaded: 0, total: 4)
        expectNear(fraction.value, 0.5)
        fraction.noteApply(loaded: 2, total: 4)
        expectNear(fraction.value, 0.745)
        fraction.noteApply(loaded: 1, total: 4)
        expectNear(fraction.value, 0.745)
    }

    @Test func applyWithoutDownloadFillsTowardTheCap() {
        var fraction = LibrarySyncFraction()
        fraction.noteApply(loaded: 0, total: 2)
        expectNear(fraction.value, 0)
        fraction.noteApply(loaded: 2, total: 2)
        expectNear(fraction.value, 0.99)
        #expect((fraction.value ?? 1) < 1)
    }
}

// The two-second wait is the same gate the desktop header uses so a
// short poll never flashes. The boundary is checked without sleeping.
struct LibrarySyncVisibilityTests {
    @Test func hiddenUntilTheDelayAndShownAtTheBoundary() {
        let start = ContinuousClock.now
        let delay = LibrarySyncVisibility.revealDelay
        #expect(delay == .seconds(2))
        #expect(!LibrarySyncVisibility.isRevealed(startedAt: nil, now: start))
        #expect(!LibrarySyncVisibility.isRevealed(
            startedAt: start,
            now: start.advanced(by: delay - .milliseconds(1))
        ))
        #expect(LibrarySyncVisibility.isRevealed(
            startedAt: start,
            now: start.advanced(by: delay)
        ))
    }
}

@MainActor
struct LibrarySyncProgressTests {
    @Test func staysHiddenUntilTheDelayElapses() async {
        let clock = ManualClock()
        let sleep = ControlledSleep()
        let model = makeModel(clock: clock, sleep: sleep)

        model.begin()
        await waitUntil { sleep.recorded.count == 1 }
        #expect(sleep.recorded == [.seconds(2)])
        #expect(!model.isVisible)

        clock.advance(.seconds(2) - .milliseconds(1))
        sleep.release()
        await waitUntil { sleep.exitCount >= 1 }
        #expect(!model.isVisible)
    }

    @Test func becomesVisibleWhenTheDelayElapses() async {
        let clock = ManualClock()
        let sleep = ControlledSleep()
        let model = makeModel(clock: clock, sleep: sleep)

        model.begin()
        await waitUntil { sleep.recorded.count == 1 }
        clock.advance(.seconds(2))
        sleep.release()
        await waitUntil { model.isVisible }
        #expect(model.isVisible)
    }

    @Test func progressTickDoesNotRestartTheWait() async {
        let clock = ManualClock()
        let sleep = ControlledSleep()
        let model = makeModel(clock: clock, sleep: sleep)

        model.begin()
        await waitUntil { sleep.recorded.count == 1 }
        clock.advance(.seconds(1))
        model.noteDownload(received: 1, total: 2)
        await Task.yield()
        #expect(sleep.recorded == [.seconds(2)])
        #expect(!model.isVisible)

        clock.advance(.seconds(1))
        sleep.release()
        await waitUntil { model.isVisible }
        #expect(model.isVisible)
        expectNear(model.fraction, 0.25)
    }

    @Test func cycleShorterThanTheDelayNeverAppears() async {
        let clock = ManualClock()
        let sleep = ControlledSleep()
        let model = makeModel(clock: clock, sleep: sleep)

        model.begin()
        await waitUntil { sleep.recorded.count == 1 }
        model.end()
        clock.advance(.seconds(5))
        sleep.release()
        await waitUntil { sleep.exitCount >= 1 }
        #expect(!model.isVisible)
        #expect(model.fraction == nil)
    }

    @Test func nestedBeginDoesNotHideTheOuterPull() async {
        let clock = ManualClock()
        let sleep = ControlledSleep()
        let model = makeModel(clock: clock, sleep: sleep)

        model.begin()
        await waitUntil { sleep.recorded.count == 1 }
        clock.advance(.seconds(2))
        sleep.release()
        await waitUntil { model.isVisible }

        model.noteDownload(received: 1, total: 2)
        model.begin()
        model.end()
        #expect(model.isVisible)
        expectNear(model.fraction, 0.25)

        model.end()
        #expect(!model.isVisible)
        #expect(model.fraction == nil)
        model.noteDownload(received: 2, total: 2)
        #expect(model.fraction == nil)
        #expect(!model.isVisible)
    }

    @Test func trackClearsTheBarWhenThePullThrows() async {
        let model = LibrarySyncProgress(sleep: { _ in })
        struct SampleFailure: Error {}

        await #expect(throws: SampleFailure.self) {
            try await model.track {
                model.noteApply(loaded: 1, total: 2)
                throw SampleFailure()
            }
        }
        #expect(!model.isVisible)
        #expect(model.fraction == nil)
    }

    @Test func nestedTrackKeepsTheOuterFraction() async throws {
        let model = LibrarySyncProgress(sleep: { _ in })
        try await model.track {
            model.noteDownload(received: 1, total: 2)
            try await model.track {
                #expect(model.fraction != nil)
            }
            expectNear(model.fraction, 0.25)
        }
        #expect(model.fraction == nil)
        #expect(!model.isVisible)
    }

    private func makeModel(clock: ManualClock, sleep: ControlledSleep) -> LibrarySyncProgress {
        LibrarySyncProgress(sleep: { await sleep.sleep($0) }, now: { clock.now() })
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                return
            }
            await Task.yield()
        }
    }
}

private func expectNear(
    _ actual: Double?,
    _ expected: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs((actual ?? -1) - expected) < 0.0001, sourceLocation: sourceLocation)
}

// Lets a test decide when the reveal delay has elapsed without
// waiting on the real two-second timer.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant

    init() {
        instant = ContinuousClock.now
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(_ duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }
}

// Blocks the reveal task until the test has moved the clock, and
// records the delay so a progress tick cannot silently re-arm it.
private final class ControlledSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []
    private var released = false
    private var exits = 0

    func sleep(_ duration: Duration) async {
        record(duration)
        defer { markExited() }
        let start = ContinuousClock.now
        while true {
            if Task.isCancelled {
                return
            }
            if isReleased() {
                return
            }
            if ContinuousClock.now - start > .seconds(5) {
                return
            }
            await Task.yield()
        }
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    var recorded: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    var exitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exits
    }

    private func record(_ duration: Duration) {
        lock.lock()
        durations.append(duration)
        lock.unlock()
    }

    private func isReleased() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    private func markExited() {
        lock.lock()
        exits += 1
        lock.unlock()
    }
}
