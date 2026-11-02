import Combine
import Foundation
import Network

// A charging wake's answer for the path it just sampled. Unsatisfied is
// not final: the radio may still be associating.
enum AutomaticUploadPathDecision: Equatable {
    case allow
    case refuse
    case waitForSatisfiedPath
}

// Reports whether the current path would bill the user for a full-size
// media transfer, so playback and uploads can ask before starting one.
protocol NetworkCostProviding: AnyObject {
    var isMetered: Bool { get }
    var isMeteredPublisher: AnyPublisher<Bool, Never> { get }
}

// Watches the system path so fullscreen playback and uploads share one
// answer for cellular, a personal hotspot, and Low Data Mode.
final class NetworkCostMonitor: NetworkCostProviding {
    static let shared = NetworkCostMonitor()

    private let subject = CurrentValueSubject<Bool, Never>(false)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkCostMonitor")

    // Treats cellular billing and Low Data Mode as metered. Either one is
    // enough to warn, because a full-quality file is large on both.
    static func isMetered(isExpensive: Bool, isConstrained: Bool) -> Bool {
        isExpensive || isConstrained
    }

    // Automatic upload has no one to confirm a mobile-data warning, so it
    // runs only on an unmetered, unconstrained path such as Wi-Fi.
    static func allowsAutomaticUpload(
        status: NWPath.Status,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> Bool {
        status == .satisfied && !isExpensive && !isConstrained
    }

    // How long a charging wake waits for a radio that is not up yet.
    // A metered path is already an answer and is not given this grace.
    static let unsatisfiedPathGrace: TimeInterval = 5

    // The first path sample on a fresh wake is often still unsatisfied.
    // That is not a refusal. Cellular and Low Data Mode are.
    static func automaticUploadDecision(
        status: NWPath.Status,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> AutomaticUploadPathDecision {
        if isExpensive || isConstrained {
            return .refuse
        }
        if status != .satisfied {
            return .waitForSatisfiedPath
        }
        return .allow
    }

    // Waits until the path is known. A cold launch's default "not metered"
    // would start an upload before the path exists, and the first sample
    // can still be unsatisfied while the radio associates.
    func waitForAutomaticUploadDecision() async -> Bool {
        let gate = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "NetworkCostMonitor.automaticUpload")
            let finish: (Bool) -> Void = { allowed in
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: allowed)
            }
            let timeout = DispatchWorkItem { finish(false) }
            queue.asyncAfter(
                deadline: .now() + Self.unsatisfiedPathGrace,
                execute: timeout
            )
            monitor.pathUpdateHandler = { path in
                switch Self.automaticUploadDecision(
                    status: path.status,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                ) {
                case .allow:
                    timeout.cancel()
                    finish(true)
                case .refuse:
                    timeout.cancel()
                    finish(false)
                case .waitForSatisfiedPath:
                    break
                }
            }
            monitor.start(queue: queue)
        }
    }

    var isMetered: Bool {
        if Self.simulatesMeteredNetwork {
            return true
        }
        return subject.value
    }

    var isMeteredPublisher: AnyPublisher<Bool, Never> {
        if Self.simulatesMeteredNetwork {
            return Just(true).eraseToAnyPublisher()
        }
        return subject.eraseToAnyPublisher()
    }

    // Starts immediately so the first video or upload sees a path that
    // has already been classified, instead of assuming Wi-Fi.
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = Self.isMetered(
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            DispatchQueue.main.async {
                self?.subject.send(metered)
            }
        }
        monitor.start(queue: queue)
    }

    // The simulator has no cellular interface, so a debug launch argument
    // is the only way to exercise the warning there.
    private static var simulatesMeteredNetwork: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--simulate-metered-network")
        #else
        return false
        #endif
    }
}

// Lets the one-shot path check resume its continuation a single time.
// The monitor can deliver more than one update before cancel takes effect.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    // The first caller resumes the continuation. Later path updates are ignored.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }
}
