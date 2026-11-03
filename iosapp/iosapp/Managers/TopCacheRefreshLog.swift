import Combine
import Foundation

// Where a top-cache warm ran. The settings row names it, because a
// charging wake and an open timeline both fill the same cache.
enum TopCacheRefreshSource: String, Codable, Equatable {
    case open
    case charging
}

// How a top-cache warm ended. Unfinished means the process stopped
// before the warm returned, so the row still has a start time.
enum TopCacheRefreshResult: String, Codable, Equatable {
    case unfinished
    case completed
    case stoppedEarly
}

// One top-cache warm. Written when the downloads start and filled in
// when they return, so a kill still leaves the start time.
struct TopCacheRefresh: Equatable, Codable, Identifiable {
    var id: UUID
    var startedAt: Date
    var stoppedAt: Date?
    var source: TopCacheRefreshSource
    var result: TopCacheRefreshResult
}

// Turns a stored warm into the words on the Cache page. Dates stay
// local, and the second line says where the warm ran and how it ended.
enum TopCacheRefreshCopy {
    // A killed warm has a start and no stop, so the row does not invent
    // an end time.
    static func timeRange(_ refresh: TopCacheRefresh) -> String {
        guard let stoppedAt = refresh.stoppedAt else {
            return timeText(refresh.startedAt)
        }
        return "\(timeText(refresh.startedAt)) – \(timeText(stoppedAt))"
    }

    // The page uses the same endings as a charging upload, plus which
    // of the two warm paths this row came from.
    static func detail(_ refresh: TopCacheRefresh) -> String {
        "\(sourceText(refresh.source)), \(resultText(refresh.result))"
    }

    // Same clock as the Upload page, so the two settings lists read alike.
    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // The words before the comma. Each source is a path that warms
    // the top cache.
    private static func sourceText(_ source: TopCacheRefreshSource) -> String {
        switch source {
        case .open: return "While the app was open"
        case .charging: return "While charging"
        }
    }

    // The words after the comma. The same endings a charging upload uses.
    private static func resultText(_ result: TopCacheRefreshResult) -> String {
        switch result {
        case .completed: return "Completed"
        case .stoppedEarly: return "Stopped early"
        case .unfinished: return "Did not finish"
        }
    }
}

// Remembers recent top-cache warms so the Cache page can show when the
// newest thumbnails were last filled, including a warm that was killed
// before it finished. Capped so a phone that warms every night does not
// grow this list without bound.
@MainActor
final class TopCacheRefreshLog: ObservableObject {
    static let shared = TopCacheRefreshLog()
    static let historyLimit = 20

    @Published private(set) var refreshes: [TopCacheRefresh] = []

    private static let refreshesKey = "topCacheRefreshes"
    private let defaults: UserDefaults
    private let now: () -> Date

    // Lets tests use an isolated defaults suite and a fixed clock so a
    // reload sees the same rows the page will.
    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.refreshesKey),
           let stored = try? JSONDecoder().decode([TopCacheRefresh].self, from: data) {
            self.refreshes = stored
        }
    }

    // Writes a row as soon as a warm starts. A kill before the downloads
    // finish still leaves the start time on the Cache page.
    func begin(at date: Date, source: TopCacheRefreshSource) -> UUID {
        let refresh = TopCacheRefresh(
            id: UUID(),
            startedAt: date,
            stoppedAt: nil,
            source: source,
            result: .unfinished
        )
        refreshes.insert(refresh, at: 0)
        if refreshes.count > Self.historyLimit {
            refreshes.removeLast(refreshes.count - Self.historyLimit)
        }
        persist()
        return refresh.id
    }

    // Fills the row opened by begin once the warm has returned,
    // including a warm that was cancelled between thumbnails.
    func finish(id: UUID, at date: Date, result: TopCacheRefreshResult) {
        guard let index = refreshes.firstIndex(where: { $0.id == id }) else { return }
        refreshes[index].stoppedAt = date
        refreshes[index].result = result
        persist()
    }

    // Opens the row, runs the warm, then records how it ended. Both the
    // open timeline and a charging wake use this, so a cancel after the
    // start is "Stopped early" and a kill leaves the start time.
    func record(
        source: TopCacheRefreshSource,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        warm: @escaping () async -> Void
    ) async {
        let id = begin(at: now(), source: source)
        await warm()
        finish(
            id: id,
            at: now(),
            result: isCancelled() ? .stoppedEarly : .completed
        )
    }

    // Keeps the list across launches. The Cache page reads it back the
    // next time Settings is opened.
    private func persist() {
        guard let data = try? JSONEncoder().encode(refreshes) else { return }
        defaults.set(data, forKey: Self.refreshesKey)
    }
}
