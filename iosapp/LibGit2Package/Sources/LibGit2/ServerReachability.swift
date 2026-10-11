import Foundation
import Network

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

    /// A transfer failed. Only a connectivity failure counts; a cancelled
    /// request or an HTTP error is not evidence the server is gone.
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

    /// Transport failures that mean the server was not reached. A cancelled
    /// request is the user or the app stopping it, not evidence either way.
    public static func isConnectivityFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
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
