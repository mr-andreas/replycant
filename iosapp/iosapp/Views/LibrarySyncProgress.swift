import LibGit2
import SwiftUI

// Maps a pack download and the manifest apply that follows into one
// bar position. Download fills the first half. Apply continues from
// wherever that finished, and stops just short of full so the bar
// does not sit at 100% while the pull is still running. Later counts
// never move it backward: the pull fetches twice, and the second
// report is often smaller than the first.
struct LibrarySyncFraction {
    static let downloadCeiling = 0.5
    static let cap = 0.99

    private(set) var value: Double?
    private var applyOrigin: Double?

    // Records objects received for the pack. An unknown total leaves
    // the bar indeterminate, which is what a slow connect looks like
    // before git knows the pack size.
    mutating func noteDownload(received: Int, total: Int) {
        guard total > 0, received >= 0 else { return }
        let ratio = min(1, Double(received) / Double(total))
        let next = min(Self.cap, Self.downloadCeiling * ratio)
        value = max(value ?? 0, next)
    }

    // Records manifests applied. The span starts at the download
    // position so a huge apply does not jump back to zero, and a
    // pull that never downloaded still has the whole bar to cross.
    mutating func noteApply(loaded: Int, total: Int) {
        guard total > 0, loaded >= 0 else { return }
        if applyOrigin == nil {
            applyOrigin = value ?? 0
        }
        let origin = applyOrigin ?? 0
        let ratio = min(1, Double(loaded) / Double(total))
        let next = min(Self.cap, origin + (Self.cap - origin) * ratio)
        value = max(value ?? 0, next)
    }
}

// Decides when a pull has lasted long enough to show the bar. Short
// polls finish inside this window and stay silent, matching the
// desktop header.
enum LibrarySyncVisibility {
    static let revealDelay: Duration = .seconds(2)

    static func isRevealed(
        startedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        delay: Duration = revealDelay
    ) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= delay
    }
}

// Publishes one in-library pull so the shell can draw a thin bar
// without taking over the timeline. Several pulls can overlap; a
// fast skipped tryPull must not clear a pull the person is watching.
@MainActor
final class LibrarySyncProgress: ObservableObject {
    static let shared = LibrarySyncProgress()

    @Published private(set) var isVisible = false
    @Published private(set) var fraction: Double?

    private var depth = 0
    private var startedAt: ContinuousClock.Instant?
    private var progress = LibrarySyncFraction()
    private var revealTask: Task<Void, Never>?
    private let revealDelay: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        revealDelay: Duration = LibrarySyncVisibility.revealDelay,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.revealDelay = revealDelay
        self.sleep = sleep
        self.now = now
    }

    // Counts one pull. Only the outermost start arms the timer, so a
    // nested pull does not make a bar that is already due wait again.
    func begin() {
        depth += 1
        guard depth == 1 else { return }
        progress = LibrarySyncFraction()
        fraction = nil
        isVisible = false
        startedAt = now()
        let delay = revealDelay
        revealTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.revealIfStillRunning()
        }
    }

    // Drops one pull. The bar stays up until the last one finishes,
    // including when that finish is a failure.
    func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        revealTask?.cancel()
        revealTask = nil
        startedAt = nil
        progress = LibrarySyncFraction()
        fraction = nil
        isVisible = false
    }

    // Runs a pull on the caller's executor. Only the bookkeeping hops
    // to the main actor, so a large fetch does not block the timeline.
    nonisolated func track<T>(_ work: () async throws -> T) async throws -> T {
        await begin()
        do {
            let value = try await work()
            await end()
            return value
        } catch {
            await end()
            throw error
        }
    }

    func noteDownload(received: Int, total: Int) {
        guard depth > 0 else { return }
        progress.noteDownload(received: received, total: total)
        fraction = progress.value
    }

    func noteApply(loaded: Int, total: Int) {
        guard depth > 0 else { return }
        progress.noteApply(loaded: loaded, total: total)
        fraction = progress.value
    }

    // Libgit2 reports pack progress off the main thread. The hop keeps
    // the published fraction on the actor SwiftUI is reading.
    nonisolated static func receiveDownload(_ progress: GitProgress) {
        let received = Int(progress.receivedObjects)
        let total = Int(progress.totalObjects)
        Task { @MainActor in
            shared.noteDownload(received: received, total: total)
        }
    }

    // Manifest apply already counts loaded and total. The phase string
    // is for callers that show text; the bar only needs the ratio.
    nonisolated static func receiveApply(_: String, _ loaded: Int, _ total: Int) {
        Task { @MainActor in
            shared.noteApply(loaded: loaded, total: total)
        }
    }

    private func revealIfStillRunning() {
        guard depth > 0 else { return }
        guard LibrarySyncVisibility.isRevealed(
            startedAt: startedAt,
            now: now(),
            delay: revealDelay
        ) else { return }
        isVisible = true
    }
}

// Thin strip under the library title. It does not take layout space,
// so a long update can show progress without pushing the timeline.
struct LibrarySyncProgressBar: View {
    let fraction: Double?

    // Same purple as the desktop header sync bar.
    private static let fill = Color(red: 124.0 / 255, green: 58.0 / 255, blue: 237.0 / 255)

    var body: some View {
        GeometryReader { proxy in
            bar(width: proxy.size.width)
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Syncing")
        .accessibilityValue(spokenProgress)
        .accessibilityIdentifier("librarySyncProgressBar")
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        if let fraction {
            Rectangle()
                .fill(Self.fill)
                .frame(width: width * CGFloat(min(max(fraction, 0), 1)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.3), value: fraction)
        } else {
            IndeterminateSyncFill(color: Self.fill)
        }
    }

    private var spokenProgress: String {
        guard let fraction else { return "Syncing" }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        return "\(percent) percent"
    }
}

// Slides while git has not reported a count yet, the same fallback
// the desktop bar uses before the first progress event.
private struct IndeterminateSyncFill: View {
    let color: Color
    @State private var sliding = false

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(color)
                .frame(width: proxy.size.width * 0.35)
                .offset(x: sliding ? proxy.size.width : -proxy.size.width * 0.35)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                sliding = true
            }
        }
    }
}
