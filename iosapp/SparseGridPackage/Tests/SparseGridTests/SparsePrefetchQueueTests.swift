import Foundation
import Testing
@testable import SparseGrid

// Records the ids the queue asks the app to load or cancel, and supplies
// the before/after margins the cache settings would have provided.
@MainActor
private final class RecordingLoader: SparseItemLoader {
    var before = 100
    var after = 100
    private(set) var loaded: [String] = []
    private(set) var cancelled: [String] = []

    func prefetchMargins() -> (before: Int, after: Int) {
        (before, after)
    }

    func loadItem(id: String) {
        loaded.append(id)
    }

    func cancelItem(id: String) {
        cancelled.append(id)
    }

    func clearLoaded() {
        loaded.removeAll()
    }
}

// The queue chooses indices around the visible span. Loading the bytes
// is the loader's job, so these cases only check which indices qualify.
@MainActor
struct SparsePrefetchQueueTests {
    // Rapid appear calls share one trailing pass, so nothing is marked
    // in the same turn as the appear.
    @Test func rangeStaysEmptyUntilTheDebounceElapses() async throws {
        let harness = Harness(count: 20)
        for index in 0..<9 {
            harness.queue.itemDidAppear(at: index)
        }

        #expect(harness.queue.isPrefetching(index: 15) == false)

        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(harness.queue.isPrefetching(index: 12) == true)
    }

    // A burst of appears and disappears keeps only the last viewport.
    // The earlier span must not still be the one that gets warmed.
    @Test func rangeReflectsTheLastViewportAfterABurst() async throws {
        let harness = Harness(count: 50)
        for index in 0..<9 { harness.queue.itemDidAppear(at: index) }
        for index in 0..<9 { harness.queue.itemDidDisappear(at: index) }
        for index in 9..<18 { harness.queue.itemDidAppear(at: index) }

        #expect(harness.queue.isPrefetching(index: 3) == false)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(harness.queue.isPrefetching(index: 3) == true)
        #expect(harness.queue.isPrefetching(index: 25) == true)
    }

    // A flick would otherwise start a pass for every cell that flies by.
    // The pass waits until the finger and the coast have finished.
    @Test func rangeStaysEmptyWhileScrolling() async throws {
        let harness = Harness(count: 30)
        harness.queue.setScrolling(true)
        for index in 0..<9 { harness.queue.itemDidAppear(at: index) }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.queue.isPrefetching(index: 15) == false)
    }

    // Ending the flick runs the pass immediately. Waiting out the
    // debounce again would leave the next screen cold.
    @Test func rangeRunsImmediatelyWhenScrollingEnds() {
        let harness = Harness(count: 30)
        harness.queue.setScrolling(true)
        for index in 0..<9 { harness.queue.itemDidAppear(at: index) }

        harness.queue.setScrolling(false)
        #expect(harness.queue.isPrefetching(index: 15) == true)
    }

    // Margins at Int.max used to overflow the range arithmetic. The
    // visible span still expands to every loaded row.
    @Test func rangeHandlesIntMaxMarginsWithoutOverflow() {
        let harness = Harness(count: 20)
        harness.loader.before = Int.max
        harness.loader.after = Int.max
        harness.queue.setScrolling(true)
        for index in 8...10 {
            harness.queue.itemDidAppear(at: index)
        }

        harness.queue.setScrolling(false)
        #expect(harness.queue.isPrefetching(index: 0))
        #expect(harness.queue.isPrefetching(index: 19))
        #expect(harness.loader.loaded.contains("0"))
        #expect(harness.loader.loaded.contains("19"))
        #expect(!harness.loader.loaded.contains("8"))
    }

    // An id that leaves the span is cancelled so its fetch does not
    // keep a slot after the viewport has moved on.
    @Test func leavingTheRangeCancelsTheItem() async throws {
        let harness = Harness(count: 40, before: 2, after: 2)
        harness.queue.setScrolling(true)
        for index in 10..<15 { harness.queue.itemDidAppear(at: index) }
        harness.queue.setScrolling(false)
        #expect(harness.loader.loaded.contains("8"))

        harness.loader.clearLoaded()
        harness.queue.setScrolling(true)
        for index in 10..<15 { harness.queue.itemDidDisappear(at: index) }
        for index in 20..<25 { harness.queue.itemDidAppear(at: index) }
        harness.queue.setScrolling(false)

        #expect(harness.loader.cancelled.contains("8"))
        #expect(harness.loader.loaded.contains("18"))
    }
}

@MainActor
private struct Harness {
    let loader = RecordingLoader()
    let queue: SparsePrefetchQueue<GridRow>

    init(count: Int, before: Int = 100, after: Int = 100) {
        let source = MemoryPageSource(count: count)
        let window = SparseIndexWindow<GridRow>(source: source)
        window.totalCount = count
        window.updateRegion { region in
            region.loadedOffset = 0
            region.items = (0..<count).map { GridRow(id: "\($0)") }
            return false
        }
        loader.before = before
        loader.after = after
        queue = SparsePrefetchQueue(window: window)
        queue.loader = loader
    }
}
