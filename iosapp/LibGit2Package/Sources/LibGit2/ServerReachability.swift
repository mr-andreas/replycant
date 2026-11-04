import Foundation
import Network

/// What a screen shows when a transfer never reached the library server.
///
/// URLSession calls that failure "bad URL" when gitd is stopped. The
/// transports keep the raw error for the log and the banner, and hand
/// this to the user.
public struct ServerUnreachableError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "The library server cannot be reached."
    }
}

extension Notification.Name {
    /// Posted when the latest evidence about reaching the server changes,
    /// so the connection banner can follow it without polling.
    public static let serverReachabilityDidChange = Notification.Name(
        "replycant.serverReachabilityDidChange"
    )
}

/// Remembers whether the latest evidence says this device can reach the server.
///
/// The tailnet node stays Running with no network at all, and a request that
/// dies inside the node's proxy looks like a timeout rather than "no
/// internet". Nothing else tells the user the library is out of reach, so
/// path changes and the outcome of real gitd traffic both land here.
public final class ServerReachability: @unchecked Sendable {
    /// The instance the transports report to. It is the only one that
    /// watches the system path; tests drive the path themselves.
    public static let shared: ServerReachability = ServerReachability(monitorsPath: true)

    private let notifications: NotificationCenter
    private let lock = NSLock()
    private var reachable = true
    private var pathMonitor: NWPathMonitor?

    /// - Parameter monitorsPath: watches the system path so a phone with
    ///   no network at all is unreachable before a request has to time
    ///   out. Left off everywhere except `shared`, so a test can decide
    ///   the path itself.
    public init(
        notifications: NotificationCenter = .default,
        monitorsPath: Bool = false
    ) {
        self.notifications = notifications
        if monitorsPath {
            startPathMonitor()
        }
    }

    public var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    /// An HTTP response arrived, whatever status it carried. The server
    /// was reached.
    public func recordResponse() {
        update(reachable: true)
    }

    /// A transfer failed. Only a failure that never reached the server
    /// counts. A cancelled request is the app stopping it, and an HTTP
    /// status means gitd answered, so callers do not pass those here.
    public func recordFailure(_ error: Error) {
        guard Self.isConnectivityFailure(error) else { return }
        update(reachable: false)
    }

    /// The system path changed. Unsatisfied means there is no network to
    /// send on. Satisfied only means a network exists again: the next
    /// request is what shows whether the server is actually reachable.
    public func recordPath(satisfied: Bool) {
        update(reachable: satisfied)
    }

    /// A URLSession failure that ended with no HTTP response.
    ///
    /// Callers record a response before they record a failure, so this
    /// only sees attempts that never reached gitd. Cancellation is the
    /// app stopping the transfer, which is not evidence the server is
    /// gone. A stopped gitd fails as a bad URL, the same situation as
    /// a timeout.
    public static func isConnectivityFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return nsError.code != NSURLErrorCancelled
    }

    /// The error a screen should show for this failure.
    ///
    /// A transfer that never reached the library server is one sentence.
    /// A refusal, a pause, or an HTTP status stays the caller's error,
    /// because those are different problems.
    public static func presented(_ error: Error) -> Error {
        guard isConnectivityFailure(error) else { return error }
        return ServerUnreachableError()
    }

    /// Stops the path watch when a monitored instance is released.
    deinit {
        pathMonitor?.cancel()
    }

    private func update(reachable: Bool) {
        lock.lock()
        let changed = self.reachable != reachable
        self.reachable = reachable
        lock.unlock()
        guard changed else { return }
        notifications.post(name: .serverReachabilityDidChange, object: self)
    }

    /// A path that is not satisfied is a phone with nowhere to send, which
    /// is the case a request timeout would only notice a minute later.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.recordPath(satisfied: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "ServerReachability"))
        pathMonitor = monitor
    }
}
