import Testing
@testable import iosapp

// Verifies simulator auto-connect skips generated keys only when
// bundled credentials will actually replace them.
struct SimulatorAutoConnectManagerTests {
    // Recovery on a fresh simulator install needs a generated device
    // key when SimulatorCredentials/ is absent.
    @Test func skipsGeneratedKeyOnlyWhenBundledCredentialsExist() {
        #expect(
            SimulatorAutoConnectManager.shouldSkipGeneratedDeviceKey(
                isAutoConnectEnabled: true,
                hasBundledSimulatorCredentials: false
            ) == false
        )
        #expect(
            SimulatorAutoConnectManager.shouldSkipGeneratedDeviceKey(
                isAutoConnectEnabled: true,
                hasBundledSimulatorCredentials: true
            ) == true
        )
        #expect(
            SimulatorAutoConnectManager.shouldSkipGeneratedDeviceKey(
                isAutoConnectEnabled: false,
                hasBundledSimulatorCredentials: true
            ) == false
        )
    }
}
