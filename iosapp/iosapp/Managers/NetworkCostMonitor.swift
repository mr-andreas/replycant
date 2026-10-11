import Combine
import Foundation
import Network

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
