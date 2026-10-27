import Combine
import Foundation
import Testing
import UserNotifications
@testable import iosapp

// Checks the one upload switch: permission, the stall question, and
// that an automatic run waits until the timeline has loaded and Wi-Fi
// is available.
@Suite("Upload controller", .serialized)
@MainActor
struct UploadControllerTests {
    @Test("Refused photo access leaves upload off and explains how to allow it")
    func testPhotoRefusalDoesNotEnable() async {
        let harness = Harness()
        harness.photos.requestResult = false

        await harness.controller.enable()

        #expect(harness.controller.isEnabled == false)
        #expect(harness.scheduler.setEnabledCalls.isEmpty)
        #expect(harness.controller.pendingPrompt == .photoAccessDenied)
        #expect(harness.runner.startedOrders.isEmpty)
    }

    @Test("Allowing photos turns upload on and asks about a stall reminder")
    func testGrantAsksTheReminderQuestion() async {
        let harness = Harness()

        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        #expect(harness.controller.isEnabled == true)
        #expect(harness.scheduler.isEnabled == true)
        #expect(harness.controller.pendingPrompt == .reminderQuestion)
        #expect(harness.runner.startedOrders.isEmpty)
    }

    @Test("A notification denial skips the reminder question and still uploads")
    func testDeniedNotificationsSkipTheQuestion() async {
        let harness = Harness()
        harness.reminders.status = .denied

        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        #expect(harness.controller.pendingPrompt == nil)
        #expect(harness.runner.startedOrders == [.newestFirst])
        #expect(harness.reminders.authorizationRequests == 0)
    }

    @Test("Yes turns reminders on and asks the system only when it has not asked before")
    func testYesTurnsRemindersOn() async {
        let harness = Harness()
        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        harness.controller.answerReminderQuestion(allowReminders: true)
        await harness.waitUntil {
            harness.reminders.authorizationRequests == 1
                && harness.runner.startedOrders == [.newestFirst]
        }

        #expect(harness.reminders.remindersEnabled == true)
        #expect(harness.controller.pendingPrompt == nil)
    }

    @Test("Yes does not show the system prompt again when notifications are already allowed")
    func testYesSkipsPromptWhenAlreadyAuthorized() async {
        let harness = Harness()
        harness.reminders.status = .authorized
        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        harness.controller.answerReminderQuestion(allowReminders: true)
        await harness.waitUntil { harness.runner.startedOrders == [.newestFirst] }

        #expect(harness.reminders.authorizationRequests == 0)
        #expect(harness.reminders.remindersEnabled == true)
    }

    @Test("No turns reminders off and never asks the system for notification access")
    func testNoTurnsRemindersOffWithoutAsking() async {
        let harness = Harness()
        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        harness.controller.answerReminderQuestion(allowReminders: false)
        await harness.waitUntil { harness.runner.startedOrders == [.newestFirst] }

        #expect(harness.reminders.remindersEnabled == false)
        #expect(harness.reminders.authorizationRequests == 0)
    }

    @Test("Turning upload off stops the current run and the charging task")
    func testDisableCancelsTheRun() async {
        let harness = Harness()
        harness.reminders.status = .denied
        await harness.controller.launchDidFinish()
        await harness.controller.enable()
        #expect(harness.runner.startedOrders == [.newestFirst])

        await harness.controller.disable()

        #expect(harness.controller.isEnabled == false)
        #expect(harness.scheduler.isEnabled == false)
        #expect(harness.scheduler.setEnabledCalls == [true, false])
        #expect(harness.runner.cancelCount == 1)
    }

    @Test("Dismissing the banner is remembered and points the user at Settings")
    func testDismissPersistsAndExplainsSettings() {
        let harness = Harness()

        harness.controller.dismissPrompt()

        #expect(harness.controller.isPromptDismissed == true)
        #expect(harness.controller.pendingPrompt == .dismissedHint)
        #expect(UploadPrompt.dismissedHint.message == "You can turn on upload anytime in Settings.")
        #expect(UploadPrompt.reminderQuestion.message == "Uploads keep going on Wi-Fi while your phone is charging, even with the app closed. If they stay unfinished for a while, Replycant can send a notification.")

        let restored = Harness(defaults: harness.defaults)
        #expect(restored.controller.isPromptDismissed == true)
        #expect(restored.controller.pendingPrompt == nil)
    }

    @Test("Nothing uploads until the first timeline load has finished")
    func testNothingStartsBeforeLaunchFinishes() async {
        let harness = Harness()
        harness.reminders.status = .denied

        await harness.controller.enable()
        #expect(harness.runner.startedOrders.isEmpty)

        await harness.controller.launchDidFinish()
        #expect(harness.runner.startedOrders == [.newestFirst])
    }

    @Test("An automatic run needs the switch, photo access, Wi-Fi, and a free uploader")
    func testStartRequiresEveryCondition() async {
        let disabled = Harness()
        disabled.photos.isAuthorized = true
        await disabled.controller.launchDidFinish()
        await disabled.controller.startIfReady()
        #expect(disabled.runner.startedOrders.isEmpty)

        let noPhotos = Harness()
        await noPhotos.scheduler.setEnabled(true)
        noPhotos.photos.isAuthorized = false
        await noPhotos.controller.launchDidFinish()
        #expect(noPhotos.runner.startedOrders.isEmpty)

        let metered = Harness()
        metered.reminders.status = .denied
        metered.gate.allows = false
        await metered.controller.launchDidFinish()
        await metered.controller.enable()
        #expect(metered.runner.startedOrders.isEmpty)

        let busy = Harness()
        busy.reminders.status = .denied
        busy.runner.isSyncing = true
        await busy.controller.launchDidFinish()
        await busy.controller.enable()
        #expect(busy.runner.startedOrders.isEmpty)
    }

    @Test("Regaining Wi-Fi starts a run that mobile data had blocked")
    func testRegainingWiFiStarts() async {
        let harness = Harness()
        harness.reminders.status = .denied
        harness.gate.allows = false
        await harness.controller.launchDidFinish()
        await harness.controller.enable()
        #expect(harness.runner.startedOrders.isEmpty)

        harness.gate.allows = true
        harness.network.subject.send(false)
        await harness.waitUntil { harness.runner.startedOrders == [.newestFirst] }
    }

    @Test("A UI test launch never starts an upload on its own")
    func testUITestingDoesNotAutoStart() async {
        let harness = Harness(launchArguments: ["--uitesting"])
        harness.reminders.status = .denied

        await harness.controller.launchDidFinish()
        await harness.controller.enable()

        #expect(harness.controller.isEnabled == true)
        #expect(harness.runner.startedOrders.isEmpty)
    }

    @Test("The enable banner shows only while upload is off, not dismissed, and the timeline has photos")
    func testShowsEnableBanner() {
        for enabled in [false, true] {
            for dismissed in [false, true] {
                for empty in [false, true] {
                    #expect(
                        UploadController.showsEnableBanner(
                            isEnabled: enabled,
                            isDismissed: dismissed,
                            isTimelineEmpty: empty
                        ) == (!enabled && !dismissed && !empty)
                    )
                }
            }
        }
    }
}

// Checks the words on the progress sheet. A 0-of-0 bar used to be the
// only thing on screen while the library was still being scanned.
@Suite("Upload details copy")
struct UploadDetailsCopyTests {
    @Test("A scan with no total keeps the phase as the headline")
    func testPreparingHeadline() {
        #expect(PhotoSyncStatusCopy.headline(
            current: 0,
            total: 0,
            file: "Asking for photo access..."
        ) == "Asking for photo access...")
        #expect(PhotoSyncStatusCopy.headline(
            current: 3,
            total: 10,
            file: "IMG.HEIC"
        ) == "Uploading 3 of 10")
    }

    @Test("Mobile data pause reads as waiting for Wi-Fi, and a failure can be retried")
    func testFailureAndPauseCopy() {
        let paused = SyncState.failed(UploadPausedOnMobileDataError())
        #expect(UploadDetailsCopy.activityIndicator(for: paused) == .waitingForWiFi)
        #expect(UploadDetailsCopy.title(for: paused) == "Waiting for Wi-Fi")
        #expect(UploadDetailsCopy.showsRetry(paused))

        let failed = SyncState.failed(PhotoLibraryError.accessDenied)
        #expect(UploadDetailsCopy.activityIndicator(for: failed) == .failed)
        #expect(UploadDetailsCopy.title(for: failed) == "Upload failed")
        #expect(UploadDetailsCopy.showsRetry(failed))

        let syncing = SyncState.syncing(
            current: 1,
            total: 4,
            currentFile: "a.jpg",
            uploadSpeed: "",
            fileSize: ""
        )
        #expect(UploadDetailsCopy.activityIndicator(for: syncing) == .inProgress(current: 1, total: 4))
        #expect(UploadDetailsCopy.showsRetry(syncing) == false)
        #expect(UploadDetailsCopy.activityIndicator(for: .idle) == .hidden)
        #expect(UploadDetailsCopy.activityIndicator(for: .completed(total: 3)) == .hidden)
    }
}

// Builds one controller against fakes so a test never touches Photos,
// the system scheduler, or this phone's upload switch.
@MainActor
private struct Harness {
    let controller: UploadController
    let scheduler: FakeUploadSwitch
    let runner: FakeUploadRunner
    let photos: FakePhotoAccess
    let reminders: FakeReminderPreference
    let network: FakeUploadNetwork
    let gate: UploadGate
    let defaults: UserDefaults

    init(
        defaults existing: UserDefaults? = nil,
        launchArguments: [String] = []
    ) {
        let defaults: UserDefaults
        if let existing {
            defaults = existing
        } else {
            let suite = "upload-controller-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }
        let scheduler = FakeUploadSwitch()
        let runner = FakeUploadRunner()
        let photos = FakePhotoAccess()
        let reminders = FakeReminderPreference()
        let network = FakeUploadNetwork()
        let gate = UploadGate()
        self.defaults = defaults
        self.scheduler = scheduler
        self.runner = runner
        self.photos = photos
        self.reminders = reminders
        self.network = network
        self.gate = gate
        self.controller = UploadController(
            scheduler: scheduler,
            upload: runner,
            photos: photos,
            reminders: reminders,
            network: network,
            allowsAutomaticUpload: { gate.allows },
            defaults: defaults,
            launchArguments: launchArguments
        )
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition())
    }
}

// Remembers the switch so a test can see enable and disable without
// BGTaskScheduler, which the simulator refuses.
@MainActor
private final class FakeUploadSwitch: UploadEnabling {
    var isEnabled = false
    private(set) var setEnabledCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        setEnabledCalls.append(enabled)
    }
}

// Records start and cancel. The real uploader needs a repository.
@MainActor
private final class FakeUploadRunner: UploadRunning {
    var isSyncing = false
    private(set) var startedOrders: [UploadOrder] = []
    private(set) var cancelCount = 0

    func startSync(order: UploadOrder) async {
        startedOrders.append(order)
        isSyncing = true
    }

    func cancelSync() {
        cancelCount += 1
        isSyncing = false
    }
}

// Photo permission without Photos. A refusal stays unauthorized so a
// later automatic start does not treat it as granted.
private final class FakePhotoAccess: PhotoAccessRequesting {
    var isAuthorized = false
    var requestResult = true
    private(set) var requestCount = 0

    func requestAuthorization() async -> Bool {
        requestCount += 1
        isAuthorized = requestResult
        return requestResult
    }
}

// The stall-reminder choice and the system prompt, without UserNotifications.
@MainActor
private final class FakeReminderPreference: UploadReminderPreference {
    var remindersEnabled = true
    var status: UNAuthorizationStatus = .notDetermined
    private(set) var authorizationRequests = 0

    func setRemindersEnabled(_ enabled: Bool) async {
        remindersEnabled = enabled
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = .authorized
        return true
    }
}

// Starts metered so subscribing does not look like Wi-Fi returning.
private final class FakeUploadNetwork: NetworkCostProviding {
    let subject = CurrentValueSubject<Bool, Never>(true)
    var isMetered: Bool { subject.value }
    var isMeteredPublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

// Lets a test flip Wi-Fi after the controller has already been built.
private final class UploadGate: @unchecked Sendable {
    var allows = true
}
