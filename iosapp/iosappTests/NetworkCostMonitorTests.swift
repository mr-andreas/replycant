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
}
