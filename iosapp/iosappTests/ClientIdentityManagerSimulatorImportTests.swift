import Foundation
import Testing
@testable import iosapp

// Verifies simulator bootstrap stays optional so the repo never needs committed private keys.
@MainActor
@Suite(.sharedAppState)
struct ClientIdentityManagerSimulatorImportTests {

    // Confirms missing local SimulatorCredentials do not fail launch prep.
    @Test func testSimulatorBundledImportSkipsWhenCredentialsMissing() throws {
        #if DEBUG && targetEnvironment(simulator)
        try ClientIdentityManager.shared.importBundledSimulatorIdentityIfNeeded()
        #else
        return
        #endif
    }
}
