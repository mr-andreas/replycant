import Network
import Testing
@testable import iosapp

// Locks the metered-network rule so cellular, hotspot, and Low Data Mode
// all warn before a full-size transfer, while ordinary Wi-Fi does not.
@Suite("Network Cost Monitor Tests")
struct NetworkCostMonitorTests {
    @Test func expensivePathIsMetered() {
        #expect(NetworkCostMonitor.isMetered(isExpensive: true, isConstrained: false))
    }

    @Test func constrainedPathIsMetered() {
        #expect(NetworkCostMonitor.isMetered(isExpensive: false, isConstrained: true))
    }

    @Test func unconstrainedWifiIsNotMetered() {
        #expect(!NetworkCostMonitor.isMetered(isExpensive: false, isConstrained: false))
    }

    // A charging wake's first sample is often still unsatisfied. That is
    // not a decision yet. A metered path is, and must not be waited out.
    @Test func unsatisfiedPathWaitsAndMeteredPathRefuses() {
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .unsatisfied,
            isExpensive: false,
            isConstrained: false
        ) == .waitForSatisfiedPath)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: true,
            isConstrained: false
        ) == .refuse)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: false,
            isConstrained: true
        ) == .refuse)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .unsatisfied,
            isExpensive: true,
            isConstrained: false
        ) == .refuse)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: false,
            isConstrained: false
        ) == .allow)
    }
}
