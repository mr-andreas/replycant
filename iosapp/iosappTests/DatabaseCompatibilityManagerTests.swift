import Foundation
import Testing
import GitDB
@testable import iosapp

// Verifies version refusals become a durable incompatibility the UI
// can show instead of a one-off sync error string.
@MainActor
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

    @Test func reportMapsMissingMarkerToNewLibraryGuidance() {
        let manager = DatabaseCompatibilityManager.shared
        manager.clear()
        manager.report(.missing)
        #expect(manager.incompatibility?.isNewerThanClient == false)
        #expect(
            manager.incompatibility?.userMessage
                == "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help."
        )
        manager.clear()
    }
}
