import Foundation
import Testing
@testable import iosapp

// The Cache page lists top-cache warms the way Upload lists charging
// runs. These tests pin that history: it survives a relaunch, stays
// short, and a warm that is killed still leaves its start time.
@MainActor
struct TopCacheRefreshLogTests {
    @Test("A refresh is stored newest first and survives a reload")
    func testBeginPersistsNewestFirst() {
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let later = earlier.addingTimeInterval(3600)
        let (log, defaults) = makeLog(now: later)

        _ = log.begin(at: earlier, source: .open)
        _ = log.begin(at: later, source: .charging)

        let reloaded = TopCacheRefreshLog(defaults: defaults, now: { later })
        #expect(reloaded.refreshes.map(\.startedAt) == [later, earlier])
        #expect(reloaded.refreshes.map(\.source) == [.charging, .open])
        #expect(reloaded.refreshes.allSatisfy {
            $0.stoppedAt == nil && $0.result == .unfinished
        })
    }

    // UserDefaults is a history, not a log of every night the phone
    // has charged. The newest rows are the ones the page can still show.
    @Test("Refresh history keeps the newest twenty")
    func testHistoryKeepsNewestTwenty() {
        let log = makeLog().log

        for index in 0..<25 {
            _ = log.begin(
                at: Date(timeIntervalSince1970: TimeInterval(index)),
                source: .open
            )
        }

        #expect(log.refreshes.count == 20)
        #expect(log.refreshes[0].startedAt == Date(timeIntervalSince1970: 24))
        #expect(log.refreshes.last?.startedAt == Date(timeIntervalSince1970: 5))
    }

    // The stop time and ending are what the settings row says. A reload
    // has to keep both, or the page would forget a warm that already ended.
    @Test("Finishing a refresh stores when it stopped and how it ended")
    func testFinishStoresStopAndResult() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = start.addingTimeInterval(40)
        let (log, defaults) = makeLog(now: stop)
        let id = log.begin(at: start, source: .charging)

        log.finish(id: id, at: stop, result: .completed)

        let reloaded = TopCacheRefreshLog(defaults: defaults, now: { stop })
        #expect(reloaded.refreshes.count == 1)
        #expect(reloaded.refreshes[0].startedAt == start)
        #expect(reloaded.refreshes[0].stoppedAt == stop)
        #expect(reloaded.refreshes[0].source == .charging)
        #expect(reloaded.refreshes[0].result == .completed)
    }

    // The row is written before the downloads start, so a kill during
    // the warm still has a start time. Cancellation after that start is
    // a stop, not a missing row.
    @Test("A warm records its row before it returns, then how it ended")
    func testRecordWritesBeforeTheWarmReturns() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let log = makeLog(now: { clock }).log
        var seenDuringWarm: TopCacheRefresh?

        await log.record(source: .open, isCancelled: { false }) {
            clock = start.addingTimeInterval(15)
            seenDuringWarm = log.refreshes.first
        }

        #expect(seenDuringWarm?.result == .unfinished)
        #expect(seenDuringWarm?.stoppedAt == nil)
        #expect(seenDuringWarm?.source == .open)
        #expect(log.refreshes.first?.result == .completed)
        #expect(log.refreshes.first?.stoppedAt == start.addingTimeInterval(15))

        await log.record(source: .charging, isCancelled: { true }) {}

        #expect(log.refreshes.first?.result == .stoppedEarly)
        #expect(log.refreshes.first?.source == .charging)
        #expect(log.refreshes.first?.stoppedAt != nil)
    }

    // The words on the settings row. A warm with no stop must not invent
    // an end time, and each ending is the same phrase the Upload page uses.
    @Test("Refresh copy names the time range, where it ran, and how it ended")
    func testCopy() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let stoppedAt = startedAt.addingTimeInterval(180)
        let openCompleted = TopCacheRefresh(
            id: UUID(),
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            source: .open,
            result: .completed
        )
        let chargingStopped = TopCacheRefresh(
            id: UUID(),
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            source: .charging,
            result: .stoppedEarly
        )
        let chargingUnfinished = TopCacheRefresh(
            id: UUID(),
            startedAt: startedAt,
            stoppedAt: nil,
            source: .charging,
            result: .unfinished
        )

        #expect(TopCacheRefreshCopy.timeRange(openCompleted) ==
            "\(TopCacheRefreshCopy.timeText(startedAt)) – \(TopCacheRefreshCopy.timeText(stoppedAt))")
        #expect(TopCacheRefreshCopy.timeRange(chargingUnfinished) ==
            TopCacheRefreshCopy.timeText(startedAt))
        #expect(TopCacheRefreshCopy.timeRange(chargingUnfinished).contains("–") == false)
        #expect(TopCacheRefreshCopy.detail(openCompleted) ==
            "While the app was open, Completed")
        #expect(TopCacheRefreshCopy.detail(chargingStopped) ==
            "While charging, Stopped early")
        #expect(TopCacheRefreshCopy.detail(chargingUnfinished) ==
            "While charging, Did not finish")
    }

    // Each test gets its own defaults suite so a persisted refresh
    // cannot leak into the app or another test.
    private func makeLog(
        now: @escaping () -> Date = Date.init
    ) -> (log: TopCacheRefreshLog, defaults: UserDefaults) {
        let suiteName = "TopCacheRefreshLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TopCacheRefreshLog(defaults: defaults, now: now), defaults)
    }

    private func makeLog(now: Date) -> (log: TopCacheRefreshLog, defaults: UserDefaults) {
        makeLog(now: { now })
    }
}
