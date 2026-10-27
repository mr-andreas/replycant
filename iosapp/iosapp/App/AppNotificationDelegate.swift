import Foundation
import UserNotifications

// Routes the upload reminder to the timeline. Opening the app starts
// the upload itself. Other notifications are ignored so a future alert
// cannot change the tab the user is on.
@MainActor
final class AppNotificationDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    @Published var requestedTab: Int?

    func handleNotificationTap(identifier: String) {
        guard identifier == UploadBacklogTracker.reminderIdentifier else { return }
        requestedTab = 0
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        handleNotificationTap(identifier: response.notification.request.identifier)
    }

    // Shows the reminder when it arrives while the app is already open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
