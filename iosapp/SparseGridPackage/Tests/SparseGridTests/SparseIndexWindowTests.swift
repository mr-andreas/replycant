import Foundation
import Testing
@testable import SparseGrid

// One library row. The window only needs an id, so the page tests
// stay free of manifests and thumbnails.
struct GridRow: Identifiable, Equatable {
    let id: String
}

// One page request, so a test can compare the sequence the window made.
struct PageCall: Equatable {
    let kind: String
    let detail: String
}

// Serves a fixed list of rows by offset or by the row on either edge.
// Records each request so a test can see which page the window asked for.
@MainActor
final class MemoryPageSource: SparsePageSource {
    typealias Item = GridRow

    var library: [GridRow]
    private(set) var calls: [PageCall] = []
    private var gate: CheckedContinuation<Void, Never>?
    var holdNextOffsetLoad = false
    var holdNextBeforeLoad = false

    init(count: Int) {
        library = (0..<count).map { GridRow(id: "\($0)") }
    }

    func loadPage(offset: Int, limit: Int) async throws -> [GridRow] {
        calls.append(PageCall(kind: "offset", detail: "\(offset):\(limit)"))
        if holdNextOffsetLoad {
            holdNextOffsetLoad = false
            await withCheckedContinuation { gate = $0 }
        }
        return slice(offset..<min(offset + limit, library.count))
    }

    func loadPage(before item: GridRow, limit: Int) async throws -> [GridRow] {
        calls.append(PageCall(kind: "before", detail: item.id))
        if holdNextBeforeLoad {
            holdNextBeforeLoad = false
            await withCheckedContinuation { gate = $0 }
        }
        guard let index = library.firstIndex(of: item) else { return [] }
        return slice(max(0, index - limit)..<index)
    }

    func loadPage(after item: GridRow, limit: Int) async throws -> [GridRow] {
        calls.append(PageCall(kind: "after", detail: item.id))
        guard let index = library.firstIndex(of: item) else { return [] }
        let start = index + 1
        return slice(start..<min(start + limit, library.count))
    }

    func resumeHeldLoad() {
        gate?.resume()
        gate = nil
    }

    func clearCalls() {
        calls.removeAll()
    }

    private func slice(_ range: Range<Int>) -> [GridRow] {
        guard range.lowerBound < library.count, range.lowerBound < range.upperBound else {
            return []
        }
        return Array(library[range])
    }
}

// The window keeps one contiguous range and grows it by a page when
// the grid approaches either edge. These cases lock that choice.
@MainActor
struct SparseIndexWindowTests {
    private let pageSize = 100

    // A first request is centered on the index so the rows on both
    // sides of a jump are already present.
    @Test func coldLoadCentersOnTheIndex() async {
        let source = MemoryPageSource(count: 1_000)
        let window = SparseIndexWindow<GridRow>(source: source)
        window.totalCount = 1_000

        await window.ensureLoaded(around: 250)

        #expect(source.calls == [PageCall(kind: "offset", detail: "200:\(pageSize)")])
        #expect(window.loadedOffset == 200)
        #expect(window.items.map(\.id) == (200..<300).map(String.init))
        #expect(window.revision == 1)
    }

    // An index within one page of the older edge extends the range
    // instead of throwing the loaded rows away.
    @Test func indexNearTheOlderEdgePrepends() async {
        let source = MemoryPageSource(count: 1_000)
        let window = seeded(source: source, offset: 200, count: pageSize)

        await window.ensureLoaded(around: 150)

        #expect(source.calls == [PageCall(kind: "before", detail: "200")])
        #expect(window.loadedOffset == 100)
        #expect(window.items.first?.id == "100")
        #expect(window.items.last?.id == "299")
        #expect(window.revision == 1)
    }

    // An index within one page of the newer edge appends.
    @Test func indexNearTheNewerEdgeAppends() async {
        let source = MemoryPageSource(count: 1_000)
        let window = seeded(source: source, offset: 200, count: pageSize)

        await window.ensureLoaded(around: 350)

        #expect(source.calls == [PageCall(kind: "after", detail: "299")])
        #expect(window.loadedOffset == 200)
        #expect(window.items.count == 200)
        #expect(window.items.last?.id == "399")
    }

    // A jump farther than one page replaces the range. Keeping the old
    // rows would leave a hole the grid cannot index through.
    @Test func indexFartherThanAPageReplacesTheRegion() async {
        let source = MemoryPageSource(count: 1_000)
        let window = seeded(source: source, offset: 200, count: pageSize)

        await window.ensureLoaded(around: 0)

        #expect(source.calls == [PageCall(kind: "offset", detail: "0:\(pageSize)")])
        #expect(window.loadedOffset == 0)
        #expect(window.items.map(\.id) == (0..<pageSize).map(String.init))
    }

    // A second request while a page is in flight waits for that page,
    // then loads. Dropping it left the rows on screen as placeholders.
    // One load still owns the range, so the second fetch starts only
    // after the held page returns.
    @Test func secondEnsureLoadedWhileInFlightLoadsAfterTheHeldPage() async {
        let source = MemoryPageSource(count: 1_000)
        source.holdNextOffsetLoad = true
        let window = SparseIndexWindow<GridRow>(source: source)
        window.totalCount = 1_000

        let first = Task { await window.ensureLoaded(around: 250) }
        await waitUntil { source.calls.count == 1 }
        await window.ensureLoaded(around: 10)
        #expect(source.calls.count == 1)
        source.resumeHeldLoad()
        await first.value
        #expect(source.calls == [
            PageCall(kind: "offset", detail: "200:\(pageSize)"),
            PageCall(kind: "offset", detail: "0:\(pageSize)"),
        ])
        #expect(window.loadedOffset == 0)
        #expect(window.item(at: 10)?.id == "10")
    }

    // A fling replaces the index waiting on the in-flight page. Loading
    // every index the finger passed would fetch pages the user already left.
    @Test func newerIndexReplacesTheQueuedPage() async {
        let source = MemoryPageSource(count: 1_000)
        source.holdNextOffsetLoad = true
        let window = SparseIndexWindow<GridRow>(source: source)
        window.totalCount = 1_000

        let first = Task { await window.ensureLoaded(around: 250) }
        await waitUntil { source.calls.count == 1 }
        await window.ensureLoaded(around: 10)
        await window.ensureLoaded(around: 900)
        #expect(source.calls.count == 1)
        source.resumeHeldLoad()
        await first.value
        #expect(source.calls == [
            PageCall(kind: "offset", detail: "200:\(pageSize)"),
            PageCall(kind: "offset", detail: "850:\(pageSize)"),
        ])
        #expect(window.item(at: 900)?.id == "900")
        #expect(window.item(at: 10) == nil)
    }

    // The neighbor-page fetch uses the same in-flight flag. A viewport
    // request that arrives during it has to run afterwards, or the rows
    // under the finger stay placeholders.
    @Test func requestDuringOlderPageLoadsAfterThatPage() async {
        let source = MemoryPageSource(count: 1_000)
        source.holdNextBeforeLoad = true
        let window = seeded(source: source, offset: 200, count: pageSize)

        let older = Task { await window.loadOlderPage() }
        await waitUntil { source.calls.count == 1 }
        await window.ensureLoaded(around: 900)
        #expect(source.calls.count == 1)
        source.resumeHeldLoad()
        await older.value
        #expect(source.calls == [
            PageCall(kind: "before", detail: "200"),
            PageCall(kind: "offset", detail: "850:\(pageSize)"),
        ])
        #expect(window.item(at: 900)?.id == "900")
    }

    // Cells within 24 of an unloaded neighbor pull that page in, after
    // the indices from one frame have been folded together.
    @Test func schedulePagingLoadsTheNeighborPageInsideTheEdge() async {
        let source = MemoryPageSource(count: 1_000)
        let window = seeded(source: source, offset: 200, count: pageSize)

        window.schedulePaging(around: 210)
        window.schedulePaging(around: 220)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(source.calls == [PageCall(kind: "before", detail: "200")])
        #expect(window.loadedOffset == 100)
        #expect(window.item(at: 186)?.id == "186")
    }

    // An empty neighbor page leaves the range where it is. Moving the
    // offset without rows would make every later index miss.
    @Test func emptyPageDoesNotMoveTheOffsetOrRevision() async {
        let source = MemoryPageSource(count: 1_000)
        source.library = []
        let window = seeded(source: source, offset: 200, count: pageSize)
        let revision = window.revision

        await window.ensureLoaded(around: 150)

        #expect(window.loadedOffset == 200)
        #expect(window.items.count == pageSize)
        #expect(window.revision == revision)
    }

    private func seeded(
        source: MemoryPageSource,
        offset: Int,
        count: Int
    ) -> SparseIndexWindow<GridRow> {
        let window = SparseIndexWindow<GridRow>(source: source)
        window.totalCount = source.library.isEmpty ? 1_000 : source.library.count
        let rows = (offset..<offset + count).map { GridRow(id: "\($0)") }
        window.updateRegion { region in
            region.loadedOffset = offset
            region.items = rows
            return false
        }
        source.clearCalls()
        return window
    }

    private func waitUntil(
        attempts: Int = 50,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
