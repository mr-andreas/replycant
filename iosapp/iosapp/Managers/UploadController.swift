import Combine
import Foundation
import UserNotifications

// Photo permission without the rest of the library API, so the upload
// switch can be tested without Photos.
protocol PhotoAccessRequesting: AnyObject {
    var isAuthorized: Bool { get }
    func requestAuthorization() async -> Bool
}

// The one upload switch. Foreground runs and the charging task share it,
// so turning it on in one place cannot disagree with the other.
@MainActor
protocol UploadEnabling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) async
}

// The foreground uploader, narrowed so a test can record a start without
// a repository. PhotoSyncManager is the production implementation.
@MainActor
protocol UploadRunning: AnyObject {
    var isSyncing: Bool { get }
    func startSync(order: UploadOrder) async
    func cancelSync()
}

// The stall-reminder choice. Separate from system permission: No never
// shows the system prompt, and a later Settings toggle can change it.
@MainActor
protocol UploadReminderPreference: AnyObject {
    var remindersEnabled: Bool { get }
    func setRemindersEnabled(_ enabled: Bool) async
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
}

// One alert for every place that turns upload on, so the banner, the
// empty timeline, and Settings do not each grow their own copy.
enum UploadPrompt: Equatable {
    case photoAccessDenied
    case reminderQuestion
    case dismissedHint

    var title: String {
        switch self {
        case .photoAccessDenied:
            return "Photo access needed"
        case .reminderQuestion:
            return "Get a reminder if uploads stall?"
        case .dismissedHint:
            return "Upload is off"
        }
    }

    var message: String {
        switch self {
        case .photoAccessDenied:
            return "Replycant needs access to your photo library to upload. You can allow it in Settings."
        case .reminderQuestion:
            return "Uploads keep going on Wi-Fi while your phone is charging, even with the app closed. If they stay unfinished for a while, Replycant can send a notification."
        case .dismissedHint:
            return "You can turn on upload anytime in Settings."
        }
    }
}

// Turns upload on from the timeline or Settings, then starts a run only
// after the first screen is up and the network will not bill the user.
@MainActor
final class UploadController: ObservableObject {
    static let shared = UploadController()
    static let promptDismissedKey = "uploadPromptDismissed"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPromptDismissed: Bool
    @Published private(set) var pendingPrompt: UploadPrompt?
    @Published private(set) var notificationsDenied = false

    private let scheduler: UploadEnabling
    private let upload: UploadRunning
    private let photos: PhotoAccessRequesting
    private let reminders: UploadReminderPreference
    private let allowsAutomaticUpload: () async -> Bool
    private let defaults: UserDefaults
    private let launchArguments: [String]
    private var didFinishLaunch = false
    private var waitingForReminderAnswer = false
    private var networkCancellable: AnyCancellable?

    init(
        scheduler: UploadEnabling,
        upload: UploadRunning,
        photos: PhotoAccessRequesting,
        reminders: UploadReminderPreference,
        network: NetworkCostProviding,
        allowsAutomaticUpload: @escaping () async -> Bool,
        defaults: UserDefaults,
        launchArguments: [String]
    ) {
        self.scheduler = scheduler
        self.upload = upload
        self.photos = photos
        self.reminders = reminders
        self.allowsAutomaticUpload = allowsAutomaticUpload
        self.defaults = defaults
        self.launchArguments = launchArguments
        self.isEnabled = scheduler.isEnabled
        // A screenshot library already has photos, so the enable offer
        // would cover the timeline. Leaving upload off keeps the progress
        // ring hidden too. The flag is not stored, so a later real launch
        // still asks.
        self.isPromptDismissed = defaults.bool(forKey: Self.promptDismissedKey)
            || launchArguments.contains("--screenshots")
        // A return to Wi-Fi has nobody to tap Start. The path check
        // inside startIfReady still refuses a metered network.
        networkCancellable = network.isMeteredPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isMetered in
                guard !isMetered else { return }
                Task { @MainActor in
                    await self?.startIfReady()
                }
            }
    }

    // Production wiring. Tests build a controller with fakes instead.
    convenience init() {
        self.init(
            scheduler: BackgroundUploadScheduler.shared,
            upload: PhotoSyncManager.shared,
            photos: PhotoLibraryManager(),
            reminders: UploadBacklogTracker.shared,
            network: NetworkCostMonitor.shared,
            allowsAutomaticUpload: {
                await NetworkCostMonitor.shared.waitForAutomaticUploadDecision()
            },
            defaults: .standard,
            launchArguments: ProcessInfo.processInfo.arguments
        )
    }

    // Hidden on an empty timeline because that screen has its own button,
    // and after dismiss so the user is not asked on every launch.
    static func showsEnableBanner(
        isEnabled: Bool,
        isDismissed: Bool,
        isTimelineEmpty: Bool
    ) -> Bool {
        !isEnabled && !isDismissed && !isTimelineEmpty
    }

    // Asks for the library while the app can show the system prompt.
    // Upload stays off when the user refuses. The reminder question
    // waits until photos are allowed, and a denial skips it.
    func enable() async {
        let allowed = await photos.requestAuthorization()
        guard allowed else {
            pendingPrompt = .photoAccessDenied
            return
        }
        if !scheduler.isEnabled {
            await scheduler.setEnabled(true)
        }
        isEnabled = true
        let status = await reminders.authorizationStatus()
        if UploadBacklogTracker.notificationPermissionStep(status: status) == .explain {
            waitingForReminderAnswer = true
            pendingPrompt = .reminderQuestion
            return
        }
        await startIfReady()
    }

    // Records the reminder choice, then starts. The prompt is cleared
    // before the system permission sheet so the two alerts do not stack.
    // No never requests notification access.
    func answerReminderQuestion(allowReminders: Bool) {
        guard waitingForReminderAnswer else { return }
        waitingForReminderAnswer = false
        pendingPrompt = nil
        Task { await self.applyReminderAnswer(allowReminders) }
    }

    // Stops the open run as well as the charging task. The reminder
    // preference is left as the user set it.
    func disable() async {
        waitingForReminderAnswer = false
        if pendingPrompt == .reminderQuestion {
            pendingPrompt = nil
        }
        await scheduler.setEnabled(false)
        isEnabled = false
        upload.cancelSync()
    }

    // The banner's close button. The hint is not stored: the next launch
    // stays quiet, and Settings remains the way back.
    func dismissPrompt() {
        isPromptDismissed = true
        defaults.set(true, forKey: Self.promptDismissedKey)
        pendingPrompt = .dismissedHint
    }

    // Clears a photo-access or hint alert. The reminder question is
    // cleared only by its own buttons, so a dismiss cannot answer it.
    func acknowledgePrompt() {
        guard pendingPrompt != .reminderQuestion else { return }
        pendingPrompt = nil
    }

    // Settings uses the same choice as the enable question. Undecided
    // permission is requested only when the user turns reminders on.
    func setRemindersEnabled(_ enabled: Bool) async {
        if enabled {
            let status = await reminders.authorizationStatus()
            if status == .notDetermined {
                _ = await reminders.requestAuthorization()
            }
        }
        await reminders.setRemindersEnabled(enabled)
        await refreshNotificationAccess()
    }

    // The Settings footer offers the system Settings app only after a
    // denial, which this process cannot reverse itself.
    func refreshNotificationAccess() async {
        let status = await reminders.authorizationStatus()
        notificationsDenied = status == .denied
    }

    // Called once the timeline's first load returns. Earlier scene
    // activations and network changes stay queued behind this so a
    // library scan cannot delay the first screen.
    func launchDidFinish() async {
        guard !didFinishLaunch else { return }
        didFinishLaunch = true
        await startIfReady()
    }

    // Foreground auto-start. Background charging runs do not come
    // through here. UI tests opt out so a fixture library is left alone.
    func startIfReady() async {
        guard didFinishLaunch else { return }
        guard !launchArguments.contains("--uitesting") else { return }
        guard !waitingForReminderAnswer else { return }
        guard scheduler.isEnabled else { return }
        guard photos.isAuthorized else { return }
        guard !upload.isSyncing else { return }
        guard await allowsAutomaticUpload() else { return }
        await upload.startSync(order: .newestFirst)
    }

    private func applyReminderAnswer(_ allowReminders: Bool) async {
        if allowReminders {
            let status = await reminders.authorizationStatus()
            if status == .notDetermined {
                _ = await reminders.requestAuthorization()
            }
            await reminders.setRemindersEnabled(true)
        } else {
            await reminders.setRemindersEnabled(false)
        }
        await startIfReady()
    }
}
