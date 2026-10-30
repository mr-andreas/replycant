import SwiftUI
import UIKit

// Turns a stored charging run into the words on the settings page.
// Dates stay local; counts stay plain so a row can be read at a glance.
enum BackgroundUploadStatusCopy {
    struct SummaryRow: Equatable, Identifiable {
        var title: String
        var value: String
        var id: String { title }
    }

    // Registration is per launch. Nil means this process has not tried,
    // which the page shows as No rather than a third state.
    static func summaryRows(for status: BackgroundUploadStatus) -> [SummaryRow] {
        let scheduled: String
        if let error = status.lastScheduleError {
            scheduled = error
        } else if let date = status.lastScheduledAt {
            scheduled = timeText(date)
        } else {
            scheduled = "Not scheduled"
        }
        return [
            SummaryRow(title: "Registered", value: status.isRegistered == true ? "Yes" : "No"),
            SummaryRow(title: "Last scheduled", value: scheduled)
        ]
    }

    // A killed run has a start and no stop, so the row does not invent
    // an end time.
    static func timeRange(_ run: BackgroundUploadRun) -> String {
        guard let stoppedAt = run.stoppedAt else {
            return timeText(run.startedAt)
        }
        return "\(timeText(run.startedAt)) – \(timeText(stoppedAt))"
    }

    // Files include videos. Bytes are the plaintext originals, which is
    // the size shown while an upload is in progress, not thumbnails.
    // The count is what was still left when the run stopped.
    static func runDetail(_ run: BackgroundUploadRun) -> String {
        let files = run.uploadedCount == 1 ? "1 file" : "\(run.uploadedCount) files"
        let left = run.queueCount.map { "\($0) left" } ?? "—"
        return "\(files), \(bytesText(run.uploadedBytes)), \(left), \(resultLabel(run.result))"
    }

    static func resultLabel(_ result: BackgroundUploadRunResult) -> String {
        switch result {
        case .completed: return "Completed"
        case .expired: return "Stopped early"
        case .alreadyUploading: return "Already uploading"
        case .skipped: return "Skipped"
        case .unfinished: return "Did not finish"
        }
    }

    static func bytesText(_ bytes: Int64) -> String {
        let kilobyte: Int64 = 1024
        let megabyte = kilobyte * 1024
        let gigabyte = megabyte * 1024
        if bytes < kilobyte {
            return "\(bytes) bytes"
        }
        if bytes < megabyte {
            return "\(bytes / kilobyte) KB"
        }
        if bytes < gigabyte {
            return "\(bytes / megabyte) MB"
        }
        return "\(bytes / gigabyte) GB"
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// The upload switch and the charging-run list. One page, because they
// are the same choice: on means Wi-Fi uploads now and while charging.
struct BackgroundUploadSettingsView: View {
    private let previewStatus: BackgroundUploadStatus?
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var scheduler = BackgroundUploadScheduler.shared
    @ObservedObject private var uploadController = UploadController.shared
    @ObservedObject private var uploadBacklog = UploadBacklogTracker.shared
    @State private var wantsUpload: Bool
    @State private var wantsReminders: Bool

    init(previewStatus: BackgroundUploadStatus? = nil) {
        self.previewStatus = previewStatus
        _wantsUpload = State(initialValue: UploadController.shared.isEnabled)
        _wantsReminders = State(initialValue: UploadBacklogTracker.shared.remindersEnabled)
    }

    private var status: BackgroundUploadStatus {
        previewStatus ?? scheduler.status
    }

    var body: some View {
        Form {
            uploadControls
            Section {
                ForEach(BackgroundUploadStatusCopy.summaryRows(for: status)) { row in
                    LabeledContent(row.title, value: row.value)
                }
            }
            Section {
                if status.runs.isEmpty {
                    Text("No background runs yet")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("backgroundUploadRuns")
                } else {
                    ForEach(status.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(BackgroundUploadStatusCopy.timeRange(run))
                            Text(BackgroundUploadStatusCopy.runDetail(run))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("backgroundUploadRun")
                    }
                }
            } header: {
                Text("Runs")
            } footer: {
                Text("Runs while the phone is charging and on Wi-Fi. A force quit, Low Power Mode, or Background App Refresh off keeps iOS from running it.")
            }
        }
        .navigationTitle("Upload")
        .task { await uploadController.refreshNotificationAccess() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await uploadController.refreshNotificationAccess() }
        }
        .onChange(of: wantsUpload) { _, enabled in
            guard enabled != uploadController.isEnabled else { return }
            Task {
                if enabled {
                    await uploadController.enable()
                } else {
                    await uploadController.disable()
                }
                wantsUpload = uploadController.isEnabled
            }
        }
        .onChange(of: uploadController.isEnabled) { _, enabled in
            wantsUpload = enabled
        }
        .onChange(of: wantsReminders) { _, enabled in
            guard enabled != uploadBacklog.remindersEnabled else { return }
            Task { await uploadController.setRemindersEnabled(enabled) }
        }
        .onChange(of: uploadBacklog.remindersEnabled) { _, enabled in
            wantsReminders = enabled
        }
    }

    // The same switch the timeline offers. Reminders stay editable after
    // the enable question so a No can be changed without turning upload off.
    private var uploadControls: some View {
        Section {
            Toggle("Upload photos and videos", isOn: $wantsUpload)
                .accessibilityIdentifier("uploadEnabledToggle")
            Toggle("Notify me if uploads stall", isOn: $wantsReminders)
                .disabled(!uploadController.isEnabled)
                .accessibilityIdentifier("uploadRemindersToggle")
        } footer: {
            if uploadController.notificationsDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notifications are off, so Replycant cannot remind you if uploads stall.")
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            } else {
                Text("New photos and videos upload on Wi-Fi. While the phone is charging, uploading also continues with the app closed.")
            }
        }
    }
}
