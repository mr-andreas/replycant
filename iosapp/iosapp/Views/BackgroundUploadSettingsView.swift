import SwiftUI

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
            SummaryRow(title: "On", value: status.isEnabled ? "Yes" : "No"),
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
    // the size the Upload tab already shows, not thumbnails.
    static func runDetail(_ run: BackgroundUploadRun) -> String {
        let files = run.uploadedCount == 1 ? "1 file" : "\(run.uploadedCount) files"
        let queued = run.queueCount.map { "\($0) queued" } ?? "—"
        return "\(files), \(bytesText(run.uploadedBytes)), \(queued), \(resultLabel(run.result))"
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

// Read-only status for the charging upload. The switch stays on the
// Upload tab; this page only explains whether iOS is running it.
struct BackgroundUploadSettingsView: View {
    private let previewStatus: BackgroundUploadStatus?
    @ObservedObject private var scheduler = BackgroundUploadScheduler.shared

    init(previewStatus: BackgroundUploadStatus? = nil) {
        self.previewStatus = previewStatus
    }

    private var status: BackgroundUploadStatus {
        previewStatus ?? scheduler.status
    }

    var body: some View {
        Form {
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
        .navigationTitle("Background upload")
    }
}
