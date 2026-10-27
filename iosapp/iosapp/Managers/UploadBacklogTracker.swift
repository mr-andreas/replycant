import Foundation
import UserNotifications

// Decides whether enabling upload asks about a stall reminder before
// iOS does. A denial cannot be asked again. Any other status still
// gets the question, because system permission is not the reminder choice.
enum NotificationPermissionStep: Equatable {
    case explain
    case skip
}

// Schedules and removes the one local reminder a backlog can have.
protocol UploadReminderNotifying: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

// Upload and a finished run share this so the reminder stays 7 days out
// while upload is on, and goes away when upload is turned off.
@MainActor
protocol UploadBacklogTracking: AnyObject {
    func start(now: Date) async
    func restartIfArmed(now: Date) async
    func clear()
}

// Keeps one reminder pending while background upload is on. The date is
// stored when the user turns it on, and moved forward whenever an upload
// finishes, so a task iOS never runs still ends in a notification.
@MainActor
final class UploadBacklogTracker: ObservableObject, UploadBacklogTracking, UploadReminderPreference {
    static let shared = UploadBacklogTracker()
    static let reminderIdentifier = "upload-backlog-reminder"
    static let startedAtDefaultsKey = "uploadBacklogStartedAt"
    static let remindersEnabledKey = "uploadRemindersEnabled"
    static let reminderDelay: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var isOverdue = false
    // Defaults to on so a library that already opted into upload keeps
    // its reminder. No, or the Settings toggle, turns it off.
    @Published private(set) var remindersEnabled: Bool

    private let defaults: UserDefaults
    private let notifications: UploadReminderNotifying

    init(
        defaults: UserDefaults = .standard,
        notifications: UploadReminderNotifying = SystemUploadReminderCenter()
    ) {
        self.defaults = defaults
        self.notifications = notifications
        self.remindersEnabled = defaults.object(forKey: Self.remindersEnabledKey) as? Bool ?? true
        #if DEBUG
        if let override = Self.debugBacklogStart(
            arguments: ProcessInfo.processInfo.arguments,
            now: Date()
        ) {
            backlogStartedAt = override
            // A debug launch that is already past the deadline also posts the
            // reminder, so the tap that opens the timeline can be checked
            // without waiting 7 days. With permission refused, nothing is posted.
            Task { await scheduleReminder(now: Date()) }
        }
        #endif
        refreshOverdue()
    }

    // Asks unless iOS has already denied notifications. An earlier allow
    // is not the reminder choice, and a denial cannot show the prompt again.
    static func notificationPermissionStep(
        status: UNAuthorizationStatus
    ) -> NotificationPermissionStep {
        status == .denied ? .skip : .explain
    }

    // The warning appears once uploads have been unfinished for 7 days.
    static func isOverdue(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= reminderDelay
    }

    // Starts the clock at now and schedules the reminder a full 7 days
    // later. Calling it again replaces that reminder, which is how a
    // finished upload postpones it.
    func start(now: Date) async {
        backlogStartedAt = now
        refreshOverdue(now: now)
        await scheduleReminder(now: now)
    }

    // Pushes the reminder out after an upload finishes. Does nothing when
    // background upload is off, so a manual upload cannot start a reminder
    // the user never asked for.
    func restartIfArmed(now: Date) async {
        guard backlogStartedAt != nil else { return }
        notifications.removeDelivered(identifiers: [Self.reminderIdentifier])
        await start(now: now)
    }

    // Schedules the reminder after the user allows notifications. The
    // deadline stays the date the clock was armed, not the date of the grant.
    func scheduleReminderIfArmed(now: Date = Date()) async {
        await scheduleReminder(now: now)
    }

    // Settings and the enable question share this. Off removes a pending
    // reminder immediately. On schedules one only when permission exists
    // and the upload clock is already running.
    func setRemindersEnabled(_ enabled: Bool) async {
        remindersEnabled = enabled
        defaults.set(enabled, forKey: Self.remindersEnabledKey)
        if enabled {
            await scheduleReminder(now: Date())
        } else {
            notifications.removePending(identifiers: [Self.reminderIdentifier])
            notifications.removeDelivered(identifiers: [Self.reminderIdentifier])
        }
    }

    // Forwards the system status so Settings can explain a denial.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notifications.authorizationStatus()
    }

    // Forwards the system prompt. Callers invoke it only after the user
    // agrees to the stall reminder.
    func requestAuthorization() async -> Bool {
        await notifications.requestAuthorization()
    }

    // Turning background upload off drops the reminder and the warning.
    // A finished upload postpones them instead of calling this.
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

    // Skips scheduling until the user wants the reminder and notifications
    // are allowed. The stored date still drives the in-app warning.
    private func scheduleReminder(now: Date) async {
        guard remindersEnabled else { return }
        guard let started = backlogStartedAt else { return }
        let status = await notifications.authorizationStatus()
        guard status == .authorized else { return }
        let remaining = started
            .addingTimeInterval(Self.reminderDelay)
            .timeIntervalSince(now)
        let content = UNMutableNotificationContent()
        content.title = "Uploads not finished"
        content.body = "Some photos and videos have not finished uploading for 7 days. Open Replycant to finish uploading them."
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

    // The system sheet. Callers ask only after the user agrees to reminders.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
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
