import Foundation
import LibGit2

/// Decides when to warn that this device cannot reach its library.
///
/// The library is shown before the tailnet join finishes, and a joined
/// node keeps reporting Running after the phone loses its network. This
/// is what tells the user, once either of those has gone on long enough,
/// that the screen is only what this device already has.
@MainActor
final class ConnectionProblemsIndicator: ObservableObject {
    @Published private(set) var isUnreachable = false

    /// How long a check waits before the banner appears. Short of a
    /// normal join, long enough that a stalled one is not silent.
    static let stallTimeout: Duration = .seconds(5)

    private let join: @Sendable (Duration) async throws -> Void
    private let notifications: NotificationCenter
    private let reachability: ServerReachability
    /// Set when the last membership check failed. Combined with
    /// reachability so a joined phone that then loses the server still
    /// warns, and a phone that is still joining does too.
    private var joinStalled = false

    /// - Parameter join: the membership check. Production waits on the
    ///   app's single join; tests substitute a scripted outcome.
    /// - Parameter reachability: what recent traffic and the system path
    ///   say. Production uses the shared signal the transports report to.
    init(
        join: @escaping @Sendable (Duration) async throws -> Void = { timeout in
            try await TailnetBootstrap.shared.ensureJoinedIfConfigured(timeout: timeout)
        },
        notifications: NotificationCenter = .default,
        reachability: ServerReachability = .shared
    ) {
        self.join = join
        self.notifications = notifications
        self.reachability = reachability
    }

    /// Keeps the banner in step with membership and with whether the
    /// server can actually be reached, for as long as the caller is on
    /// screen.
    ///
    /// The observers are installed before the first check. A join that
    /// finishes during that check posts its notification then, and
    /// waiting to subscribe would miss it and leave the banner up.
    func watch() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let names: [Notification.Name] = [
            .tailnetMembershipDidChange,
            .serverReachabilityDidChange,
        ]
        let tokens = names.map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { _ in
                continuation.yield()
            }
        }
        defer {
            for token in tokens {
                notifications.removeObserver(token)
            }
        }

        await withTaskCancellationHandler {
            await refresh()
            for await _ in stream {
                await refresh()
            }
        } onCancel: {
            continuation.finish()
        }
    }

    /// One check. A stalled join or an unreachable server shows the
    /// banner. An unpaired device joins immediately and starts reachable,
    /// so it never warns.
    private func refresh() async {
        do {
            try await join(Self.stallTimeout)
            joinStalled = false
        } catch {
            joinStalled = true
        }
        isUnreachable = joinStalled || !reachability.isReachable
    }
}
