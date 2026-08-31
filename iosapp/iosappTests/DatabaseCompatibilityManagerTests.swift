import Foundation
import Testing
import GitDB
@testable import iosapp

// Verifies version refusals become a durable incompatibility the UI
// can show instead of a one-off sync error string.
@MainActor
@Suite(.sharedAppState)
struct DatabaseCompatibilityManagerTests {
    @Test func reportMapsNewerMarkerToUpdateGuidance() {
        let manager = DatabaseCompatibilityManager.shared
        manager.clear()
        manager.report(.unsupported(found: 2, required: 1))
        #expect(manager.incompatibility?.isNewerThanClient == true)
        #expect(
            manager.incompatibility?.userMessage
                == "This library uses database format 2. This app supports format 1. Update the app to continue."
        )
        manager.clear()
        #expect(manager.incompatibility == nil)
    }

    @Test func reportMapsRemovedMarkerToRestoreGuidance() {
        let manager = DatabaseCompatibilityManager.shared
        manager.clear()
        manager.report(.markerRemoved(previouslySynced: 1))
        #expect(manager.incompatibility?.isNewerThanClient == false)
        #expect(
            manager.incompatibility?.userMessage
                == "This library's database format marker was removed after this app last synced format 1. This is unsafe to open. Restore the marker to continue."
        )
        manager.clear()
    }

    @Test func reportMapsOlderMarkerToMigrationGuidance() {
        let manager = DatabaseCompatibilityManager.shared
        manager.clear()
        manager.report(.unsupported(found: 1, required: 2))
        #expect(manager.incompatibility?.isNewerThanClient == false)
        #expect(
            manager.incompatibility?.userMessage
                == "This library uses database format 1. This app supports format 2. Run the migration tool to continue."
        )
        manager.clear()
    }

    @Test func reportFormatTransitionDivergenceSetsResetMessage() {
        let manager = DatabaseCompatibilityManager.shared
        manager.clearFormatReset()
        manager.reportFormatTransitionDivergence(.divergedDuringFormatChange)
        #expect(manager.pendingFormatResetMessage != nil)
        #expect(manager.pendingFormatResetMessage?.contains("Discard those local changes") == true)
        manager.clearFormatReset()
        #expect(manager.pendingFormatResetMessage == nil)
    }
}
