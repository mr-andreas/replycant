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
    // not a decision yet. Cellular and Low Data Mode are, and Low Data
    // is the phrase even when the path is also expensive. The grace
    // ending on a path that never comes up is Wi-Fi not being connected.
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
        ) == .notOnWiFi)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: false,
            isConstrained: true
        ) == .lowData)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .unsatisfied,
            isExpensive: true,
            isConstrained: false
        ) == .notOnWiFi)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .unsatisfied,
            isExpensive: true,
            isConstrained: true
        ) == .lowData)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: true,
            isConstrained: true
        ) == .lowData)
        #expect(NetworkCostMonitor.automaticUploadDecision(
            status: .satisfied,
            isExpensive: false,
            isConstrained: false
        ) == .allow)
        #expect(NetworkCostMonitor.outcomeAfterGrace(.waitForSatisfiedPath) ==
            .wiFiNotConnected)
    }
}
