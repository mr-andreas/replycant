import Combine
import Foundation

// Supplies one page of items. The window never learns how a page is
// stored; the caller turns an edge item into whatever cursor it uses.
@MainActor
public protocol SparsePageSource<Item>: AnyObject {
    associatedtype Item: Identifiable where Item.ID == String

    // The page that contains `offset`, used for a first load or a jump
    // that cannot extend the current range.
    func loadPage(offset: Int, limit: Int) async throws -> [Item]

    // The page immediately before `item`, which is the first loaded row.
    func loadPage(before item: Item, limit: Int) async throws -> [Item]

    // The page immediately after `item`, which is the last loaded row.
    func loadPage(after item: Item, limit: Int) async throws -> [Item]
}

// The editable contents of the one loaded range. Manifest inserts and
// deletes change this in place so the grid keeps a single index space.
public struct SparseRegion<Item: Identifiable> where Item.ID == String {
    public var loadedOffset: Int
    public var items: [Item]

    public init(loadedOffset: Int = 0, items: [Item] = []) {
        self.loadedOffset = loadedOffset
        self.items = items
    }
}

// One contiguous run of items inside a library addressed by index.
//
// The grid is sized to the full count, but only this run is in memory.
// Scrolling to an edge extends it by one page. A jump farther away
// replaces it, because a hole would make the index arithmetic lie.
@MainActor
public final class SparseIndexWindow<Item: Identifiable> where Item.ID == String {
    // Rows fetched per page. One hundred matches the timeline's previous
    // page and keeps a jump from loading the whole library.
    public static var pageSize: Int { 100 }

    // How close to an edge a visible index must be before the neighbor
    // page is fetched. Twenty-four is a few rows on the three-column grid.
    public static var edgeThreshold: Int { 24 }

    public var totalCount: Int = 0
    public private(set) var loadedOffset: Int = 0
    public private(set) var items: [Item] = []
    public private(set) var revision: Int = 0
    public var revisionPublisher: AnyPublisher<Int, Never> {
        revisionSubject.eraseToAnyPublisher()
    }

    // A failed page leaves the previous range in place and tells the
    // caller, which is what surfaces the timeline error message.
    public var onLoadError: ((Error) -> Void)?

    // The range was dropped. Prefetch uses this to stop fetches for rows
    // that are no longer in the window. A far jump and a full reload share it.
    public var onRegionReset: (() -> Void)?

    private let source: any SparsePageSource<Item>
    private let revisionSubject = PassthroughSubject<Int, Never>()
    private var localIndexById: [String: Int] = [:]
    private var isLoadingPage = false
    // The viewport moved while a page was already loading. One load owns
    // the run, so this is the index to fetch when that load returns
    // instead of leaving those rows as placeholders.
    private var queuedIndex: Int?
    private var pendingPagingIndices: Set<Int> = []
    private var pagingTask: Task<Void, Never>?
    private let pagingDelayNanoseconds: UInt64 = 16_000_000

    public init(source: any SparsePageSource<Item>) {
        self.source = source
    }

    // The loaded row at a library index, or nil when that index is outside
    // the current run. The grid draws a placeholder for nil and asks for a page.
    public func item(at index: Int) -> Item? {
        guard index >= loadedOffset, index < loadedOffset + items.count else {
            return nil
        }
        return items[index - loadedOffset]
    }

    // Where an id sits in the library. A sync that inserts above the
    // window changes this, and the grid uses it to keep the same row.
    public func index(of id: Item.ID) -> Int? {
        guard let local = localIndexById[id] else { return nil }
        return loadedOffset + local
    }

    public var canLoadOlder: Bool { loadedOffset > 0 }

    public var canLoadNewer: Bool {
        loadedOffset + items.count < totalCount
    }

    // Loads the page that covers `index`, extending the current run when
    // the index is within one page of an edge. A second call while a page
    // is already in flight keeps the latest index and runs it when the
    // current page returns. One load still owns the run, and dropping the
    // later index left the rows on screen as placeholders.
    public func ensureLoaded(around index: Int) async {
        guard index >= 0, index < totalCount else { return }
        if item(at: index) != nil { return }
        if isLoadingPage {
            queuedIndex = index
            return
        }
        await performPageLoad {
            try await self.loadRegion(around: index)
        }
    }

    // Loads a radius around `index` so a fullscreen swipe still has rows
    // when it reaches the edge of the run that was on screen.
    public func ensureWindowLoaded(around index: Int, radius: Int = 30) async {
        await ensureLoaded(around: index)
        guard totalCount > 0 else { return }
        let start = max(0, index - radius)
        let end = min(totalCount - 1, index + radius)
        for probe in [start, end] where item(at: probe) == nil {
            await ensureLoaded(around: probe)
        }
    }

    // Folds the indices from one frame into a single page load. Cells
    // near either edge then pull the neighbor page, which is what keeps
    // a fast scroll from running into placeholders.
    public func schedulePaging(around index: Int) {
        pendingPagingIndices.insert(index)
        guard pagingTask == nil else { return }
        pagingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.pagingDelayNanoseconds ?? 16_000_000)
            guard let self else { return }
            let indices = self.pendingPagingIndices
            self.pendingPagingIndices.removeAll()
            self.pagingTask = nil
            guard let target = indices.max() else { return }
            await self.ensureLoaded(around: target)

            let olderProbe = max(0, target - Self.edgeThreshold)
            if self.item(at: olderProbe) == nil, self.canLoadOlder {
                await self.loadOlderPage()
            }
            let newerLimit = max(0, self.totalCount - 1)
            let newerProbe = min(newerLimit, target + Self.edgeThreshold)
            if self.item(at: newerProbe) == nil, self.canLoadNewer {
                await self.loadNewerPage()
            }
        }
    }

    // Drops the run without bumping the revision. A full reload changes
    // the count separately, and that is what rebuilds the grid.
    public func reset() {
        loadedOffset = 0
        items = []
        localIndexById = [:]
        onRegionReset?()
    }

    // Applies an in-place edit from the caller. The returned flag bumps
    // the revision when visible cells have to be drawn again.
    public func updateRegion(_ body: (inout SparseRegion<Item>) -> Bool) {
        var region = SparseRegion(loadedOffset: loadedOffset, items: items)
        let shouldBump = body(&region)
        loadedOffset = region.loadedOffset
        items = region.items
        rebuildIndex()
        if shouldBump {
            bumpRevision()
        }
    }

    // The page before the current run. A swipe that is about to leave
    // the loaded rows asks for this, as does a viewport sitting on the edge.
    public func loadOlderPage() async {
        guard !isLoadingPage, let edge = items.first, canLoadOlder else { return }
        await performPageLoad {
            try await self.prepend(before: edge)
        }
    }

    // The page after the current run. A swipe that is about to leave
    // the loaded rows asks for this, as does a viewport sitting on the edge.
    public func loadNewerPage() async {
        guard !isLoadingPage, let edge = items.last, canLoadNewer else { return }
        await performPageLoad {
            try await self.append(after: edge)
        }
    }

    // Runs one page fetch, then the index the viewport asked for while
    // that fetch was in flight. A neighbor page uses the same flag, so
    // the queued index has to be drained here too.
    private func performPageLoad(_ body: () async throws -> Void) async {
        isLoadingPage = true
        do {
            try await body()
        } catch {
            onLoadError?(error)
        }
        isLoadingPage = false
        while let next = queuedIndex {
            queuedIndex = nil
            guard next >= 0, next < totalCount, item(at: next) == nil else { continue }
            isLoadingPage = true
            do {
                try await loadRegion(around: next)
            } catch {
                onLoadError?(error)
            }
            isLoadingPage = false
        }
    }

    private func loadRegion(around index: Int) async throws {
        if items.isEmpty {
            try await loadFresh(offset: centeredOffset(for: index))
            return
        }

        let regionStart = loadedOffset
        let regionEnd = loadedOffset + items.count - 1
        let distanceToOlderEdge = regionStart - index
        let distanceToNewerEdge = index - regionEnd

        if distanceToOlderEdge > 0,
           distanceToOlderEdge <= Self.pageSize,
           let edge = items.first {
            try await prepend(before: edge)
            return
        }

        if distanceToNewerEdge > 0,
           distanceToNewerEdge <= Self.pageSize,
           let edge = items.last {
            try await append(after: edge)
            return
        }

        reset()
        try await loadFresh(offset: centeredOffset(for: index))
    }

    private func centeredOffset(for index: Int) -> Int {
        max(0, index - Self.pageSize / 2)
    }

    private func loadFresh(offset: Int) async throws {
        let page = try await source.loadPage(offset: offset, limit: Self.pageSize)
        loadedOffset = offset
        items = page
        rebuildIndex()
        bumpRevision()
    }

    // An empty page is not applied. Shifting the offset without rows
    // would make every later lookup miss.
    private func prepend(before edge: Item) async throws {
        let page = try await source.loadPage(before: edge, limit: Self.pageSize)
        guard !page.isEmpty else { return }
        items.insert(contentsOf: page, at: 0)
        loadedOffset = max(0, loadedOffset - page.count)
        rebuildIndex()
        bumpRevision()
    }

    private func append(after edge: Item) async throws {
        let page = try await source.loadPage(after: edge, limit: Self.pageSize)
        guard !page.isEmpty else { return }
        items.append(contentsOf: page)
        rebuildIndex()
        bumpRevision()
    }

    private func rebuildIndex() {
        localIndexById = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    private func bumpRevision() {
        revision += 1
        revisionSubject.send(revision)
    }
}
