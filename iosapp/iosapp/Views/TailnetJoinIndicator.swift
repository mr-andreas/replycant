import Foundation

/// Decides when to warn that this device has not joined its tailnet.
///
/// The library is shown before the join finishes, because the join takes
/// a couple of seconds and the local timeline does not need it. This is
/// what tells the user, once that wait has gone on long enough, that the
/// screen is only what this device already has.
@MainActor
final class TailnetJoinIndicator: ObservableObject {
    @Published private(set) var isUnreachable = false

    /// How long a check waits before the banner appears. Short of a
    /// normal join, long enough that a stalled one is not silent.
    static let stallTimeout: Duration = .seconds(5)

    private let join: @Sendable (Duration) async throws -> Void
    private let notifications: NotificationCenter

    /// - Parameter join: the membership check. Production waits on the
    ///   app's single join; tests substitute a scripted outcome.
    init(
        join: @escaping @Sendable (Duration) async throws -> Void = { timeout in
            try await TailnetBootstrap.shared.ensureJoinedIfConfigured(timeout: timeout)
        },
        notifications: NotificationCenter = .default
    ) {
        self.join = join
        self.notifications = notifications
    }

    /// Keeps the banner in step with membership for as long as the caller
    /// is on screen.
    ///
    /// The observer is installed before the first check. A join that
    /// finishes during that check posts its notification then, and
    /// waiting to subscribe would miss it and leave the banner up.
    func watch() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let token = notifications.addObserver(
            forName: .tailnetMembershipDidChange,
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield()
        }
        defer { notifications.removeObserver(token) }

        await withTaskCancellationHandler {
            await refresh()
            for await _ in stream {
                await refresh()
            }
        } onCancel: {
            continuation.finish()
        }
    }

    /// One membership check. Success hides the banner; a stall or a
    /// failure shows it. An unpaired device succeeds immediately, so it
    /// never warns.
    private func refresh() async {
        do {
            try await join(Self.stallTimeout)
            isUnreachable = false
        } catch {
            isUnreachable = true
        }
    }
}
