import Foundation
import UserNotifications

// Decides whether the Upload tab explains notifications before iOS asks.
// The system prompt is shown only after the user agrees to reminders.
enum NotificationPermissionStep: Equatable {
    case explain
    case skip
}

// Schedules and removes the one local reminder a backlog can have.
protocol UploadReminderNotifying: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

// The Upload tab and a background run share this so either one can start
// or cancel the reminder.
@MainActor
protocol UploadBacklogTracking: AnyObject {
    func arm(now: Date) async
    func clear()
}

// Remembers when uploads fell behind and asks for one reminder 7 days
// later. The date is stored up front so the reminder still fires when no
// background run happens, which is the case it is meant to catch.
@MainActor
final class UploadBacklogTracker: ObservableObject, UploadBacklogTracking {
    static let shared = UploadBacklogTracker()
    static let reminderIdentifier = "upload-backlog-reminder"
    static let startedAtDefaultsKey = "uploadBacklogStartedAt"
    static let reminderDelay: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var isOverdue = false

    private let defaults: UserDefaults
    private let notifications: UploadReminderNotifying

    init(
        defaults: UserDefaults = .standard,
        notifications: UploadReminderNotifying = SystemUploadReminderCenter()
    ) {
        self.defaults = defaults
        self.notifications = notifications
        #if DEBUG
        if let override = Self.debugBacklogStart(
            arguments: ProcessInfo.processInfo.arguments,
            now: Date()
        ) {
            backlogStartedAt = override
            // A debug launch that is already past the deadline also posts the
            // reminder, so the tap that opens Upload can be checked without
            // waiting 7 days. With permission refused, nothing is posted.
            Task { await scheduleReminder(now: Date()) }
        }
        #endif
        refreshOverdue()
    }

    // Shows the explanation only while the user has not decided. A previous
    // allow or refusal is not asked again.
    static func notificationPermissionStep(
        status: UNAuthorizationStatus
    ) -> NotificationPermissionStep {
        status == .notDetermined ? .explain : .skip
    }

    // The warning appears once uploads have been unfinished for 7 days.
    static func isOverdue(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= reminderDelay
    }

    // Starts the clock once. A later arm keeps the original deadline so a
    // repeated background run does not push the reminder further out.
    func arm(now: Date) async {
        guard backlogStartedAt == nil else { return }
        backlogStartedAt = now
        refreshOverdue(now: now)
        await scheduleReminder(now: now)
    }

    // Schedules the reminder after the user allows notifications. The
    // deadline stays the date the clock was armed, not the date of the grant.
    func scheduleReminderIfArmed(now: Date = Date()) async {
        await scheduleReminder(now: now)
    }

    // A finished upload, or turning background upload off, drops the reminder
    // and the in-app warning together.
    func clear() {
        backlogStartedAt = nil
        isOverdue = false
        notifications.removePending(identifiers: [Self.reminderIdentifier])
        notifications.removeDelivered(identifiers: [Self.reminderIdentifier])
    }

    // Recomputes the warning when the app becomes active, so a deadline
    // that passes while the app is closed is visible on the next open.
    func refreshOverdue(now: Date = Date()) {
        isOverdue = Self.isOverdue(startedAt: backlogStartedAt, now: now)
    }

    private var backlogStartedAt: Date? {
        get { defaults.object(forKey: Self.startedAtDefaultsKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.startedAtDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.startedAtDefaultsKey)
            }
        }
    }

    // Skips scheduling until notifications are allowed. The stored date still
    // drives the in-app warning.
    private func scheduleReminder(now: Date) async {
        guard let started = backlogStartedAt else { return }
        let status = await notifications.authorizationStatus()
        guard status == .authorized else { return }
        let remaining = started
            .addingTimeInterval(Self.reminderDelay)
            .timeIntervalSince(now)
        let content = UNMutableNotificationContent()
        content.title = "Uploads not finished"
        content.body = "Some photos and videos have not finished uploading for 7 days. Open Replycant and upload them with the app open."
        let request = UNNotificationRequest(
            identifier: Self.reminderIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, remaining),
                repeats: false
            )
        )
        do {
            try await notifications.add(request)
        } catch {
            logError(
                "Failed to schedule the upload reminder: \(error.localizedDescription)",
                context: "BackgroundUpload"
            )
        }
    }

    #if DEBUG
    // Lets a debug launch show the warning without waiting 7 days.
    static func debugBacklogStart(arguments: [String], now: Date) -> Date? {
        let prefix = "--upload-backlog-started-days-ago="
        guard let raw = arguments.first(where: { $0.hasPrefix(prefix) }),
              let days = Double(raw.dropFirst(prefix.count)),
              days >= 0 else {
            return nil
        }
        return now.addingTimeInterval(-days * 24 * 60 * 60)
    }
    #endif
}

// Talks to the system notification center for the one upload reminder.
final class SystemUploadReminderCenter: UploadReminderNotifying {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePending(identifiers: [String]) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
