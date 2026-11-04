import Foundation

// Loads and cancels the bytes for an id. The queue decides which ids;
// the loader knows whether those bytes are already cached.
@MainActor
public protocol SparseItemLoader: AnyObject {
    // How many loaded rows to warm before and after the visible span.
    // Read on each pass so a settings change applies without another observer.
    func prefetchMargins() -> (before: Int, after: Int)

    func loadItem(id: String)
    func cancelItem(id: String)
}

// Chooses the rows just outside the viewport and asks for their bytes.
//
// A pass waits until scrolling settles, then one trailing delay, because
// a flick would otherwise start a fetch for every cell that flies past.
// Visible rows are left to the cells. An id that leaves the span is cancelled.
@MainActor
public final class SparsePrefetchQueue<Item: Identifiable> where Item.ID == String {
    public weak var loader: (any SparseItemLoader)?

    private let window: SparseIndexWindow<Item>
    private var visibleIndices: Set<Int> = []
    private var prefetchIds: Set<String> = []
    private var isScrolling = false
    private var pending: DispatchWorkItem?
    private let debounceNanoseconds: UInt64 = 150_000_000

    public init(
        window: SparseIndexWindow<Item>,
        loader: (any SparseItemLoader)? = nil
    ) {
        self.window = window
        self.loader = loader
    }

    public func itemDidAppear(at index: Int) {
        visibleIndices.insert(index)
        schedule()
    }

    public func itemDidDisappear(at index: Int) {
        visibleIndices.remove(index)
        schedule()
    }

    // While scrolling, no pass is scheduled. Ending the scroll runs one
    // immediately so the rows about to appear are not waiting on the delay.
    public func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        guard !scrolling else { return }
        pending?.cancel()
        pending = nil
        updateRange()
    }

    // True when the last pass included this index. Visible rows are
    // included, which is how a cell can tell a warm was already requested.
    public func isPrefetching(index: Int) -> Bool {
        guard let item = window.item(at: index) else { return false }
        return prefetchIds.contains(item.id)
    }

    // Drops visible indices the library no longer contains. A count
    // change would otherwise warm a span that starts past the last row.
    public func noteTotalCount(_ count: Int) {
        visibleIndices = visibleIndices.filter { $0 >= 0 && $0 < count }
    }

    // Forgets the current warm set. A replaced range must not keep
    // fetching rows that were only in the old one. Visible indices stay
    // unless the caller is tearing the grid down.
    public func resetPrefetch(clearVisibleIndices: Bool) {
        if clearVisibleIndices {
            visibleIndices.removeAll()
        }
        let previous = prefetchIds
        prefetchIds = []
        for id in previous {
            loader?.cancelItem(id: id)
        }
    }

    // Stops a warm for ids a sync removed. The next pass would cancel
    // them too, but the fetch should not run until that delay elapses.
    public func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        prefetchIds.subtract(ids)
        for id in ids {
            loader?.cancelItem(id: id)
        }
    }

    private func schedule() {
        guard !isScrolling else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateRange()
        }
        pending = work
        let delay = DispatchTimeInterval.nanoseconds(Int(debounceNanoseconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateRange() {
        let previous = prefetchIds
        guard !visibleIndices.isEmpty, window.totalCount > 0 else {
            prefetchIds = []
            cancel(previous.subtracting(prefetchIds), keeping: [])
            return
        }

        let sorted = visibleIndices.sorted().filter { $0 >= 0 && $0 < window.totalCount }
        guard let firstVisible = sorted.first, let lastVisible = sorted.last else {
            prefetchIds = []
            cancel(previous, keeping: [])
            return
        }

        let margins = loader?.prefetchMargins() ?? (before: 0, after: 0)
        let beforeCount = clampedMargin(margins.before)
        let afterCount = clampedMargin(margins.after)
        let start = rangeStart(firstVisible: firstVisible, beforeCount: beforeCount)
        let end = rangeEnd(lastVisible: lastVisible, afterCount: afterCount)

        var nextIds = Set<String>()
        var loadIds: [String] = []
        for index in start..<end {
            guard let item = window.item(at: index) else { continue }
            nextIds.insert(item.id)
            if visibleIndices.contains(index) { continue }
            loadIds.append(item.id)
        }

        prefetchIds = nextIds
        cancel(previous, keeping: nextIds)
        for id in loadIds {
            loader?.loadItem(id: id)
        }
    }

    // Caps a margin at the library length before any subtraction, so a
    // persisted Int.max cannot overflow the index arithmetic.
    private func clampedMargin(_ margin: Int) -> Int {
        min(max(0, margin), window.totalCount)
    }

    private func rangeStart(firstVisible: Int, beforeCount: Int) -> Int {
        let (start, overflow) = firstVisible.subtractingReportingOverflow(beforeCount)
        if overflow { return 0 }
        return max(0, start)
    }

    private func rangeEnd(lastVisible: Int, afterCount: Int) -> Int {
        let (next, overflow1) = lastVisible.addingReportingOverflow(1)
        if overflow1 { return window.totalCount }
        let (end, overflow2) = next.addingReportingOverflow(afterCount)
        if overflow2 { return window.totalCount }
        return min(window.totalCount, max(0, end))
    }

    private func cancel(_ previous: Set<String>, keeping next: Set<String>) {
        for id in previous.subtracting(next) {
            loader?.cancelItem(id: id)
        }
    }
}
