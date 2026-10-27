import SwiftUI

// Copy for the upload progress sheet so a 0-of-0 bar is never the only
// thing on screen while the library is still being scanned.
enum PhotoSyncStatusCopy {
    static func headline(current: Int, total: Int, file: String) -> String {
        total == 0 ? file : "Uploading \(current) of \(total)"
    }
}

// What the timeline button shows. Hidden once a run has finished, and
// distinct for a mobile-data pause because that run resumes on its own.
enum UploadActivityIndicator: Equatable {
    case hidden
    case inProgress(current: Int, total: Int)
    case waitingForWiFi
    case failed
}

// Words and visibility for the progress sheet, kept out of the view so
// the pause and retry rules can be checked without SwiftUI.
enum UploadDetailsCopy {
    static func activityIndicator(for state: SyncState) -> UploadActivityIndicator {
        switch state {
        case .syncing(let current, let total, _, _, _):
            return .inProgress(current: current, total: total)
        case .failed(let error) where error is UploadPausedOnMobileDataError:
            return .waitingForWiFi
        case .failed:
            return .failed
        case .idle, .completed:
            return .hidden
        }
    }

    static func title(for state: SyncState) -> String {
        switch state {
        case .syncing(let current, let total, let file, _, _):
            return PhotoSyncStatusCopy.headline(current: current, total: total, file: file)
        case .failed(let error) where error is UploadPausedOnMobileDataError:
            return "Waiting for Wi-Fi"
        case .failed:
            return "Upload failed"
        case .completed(let total):
            return "Uploaded \(total) files"
        case .idle:
            return "Upload"
        }
    }

    static func showsRetry(_ state: SyncState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    static func accessibilityLabel(for state: SyncState) -> String {
        switch activityIndicator(for: state) {
        case .inProgress:
            return "Uploading"
        case .waitingForWiFi:
            return "Upload paused"
        case .failed:
            return "Upload failed"
        case .hidden:
            return "Upload"
        }
    }
}

// Progress for the open run. Tapping the timeline button presents it.
// A mobile-data pause says it is waiting, because the run continues
// on its own when Wi-Fi returns.
struct UploadDetailsView: View {
    @ObservedObject var syncManager: PhotoSyncManager
    var isOverdue: Bool
    var onRetry: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusContent
                if isOverdue {
                    overdueWarning
                }
                if UploadDetailsCopy.showsRetry(syncManager.syncState) {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("uploadRetryButton")
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch syncManager.syncState {
        case .idle:
            Text("Ready to upload")
                .foregroundStyle(.secondary)
        case .syncing(_, let total, let currentFile, let uploadSpeed, let fileSize):
            VStack(spacing: 10) {
                if total == 0 {
                    ProgressView()
                } else {
                    ProgressView(
                        value: Double(progressCurrent),
                        total: Double(total)
                    )
                }
                Text(UploadDetailsCopy.title(for: syncManager.syncState))
                    .font(.headline)
                if total > 0 {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !fileSize.isEmpty {
                    HStack(spacing: 15) {
                        Label(fileSize, systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !uploadSpeed.isEmpty && uploadSpeed != "Preparing..." {
                            Label(uploadSpeed, systemImage: "arrow.up.circle")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        case .completed:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text(UploadDetailsCopy.title(for: syncManager.syncState))
                    .font(.headline)
            }
        case .failed(let error):
            VStack(spacing: 10) {
                Image(
                    systemName: error is UploadPausedOnMobileDataError
                        ? "pause.circle"
                        : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 44))
                .foregroundStyle(error is UploadPausedOnMobileDataError ? Color.secondary : Color.red)
                Text(UploadDetailsCopy.title(for: syncManager.syncState))
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var progressCurrent: Int {
        if case .syncing(let current, _, _, _, _) = syncManager.syncState {
            return current
        }
        return 0
    }

    private var overdueWarning: some View {
        Text("Some photos and videos have not finished uploading for 7 days. Keep Replycant open on Wi-Fi until the upload finishes.")
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.orange)
            .cornerRadius(10)
            .accessibilityIdentifier("uploadBacklogWarning")
    }
}

// The timeline's upload button. A ring while bytes are moving, and an
// icon when the last run stopped, so progress is visible without a tab.
struct UploadProgressButton: View {
    let state: SyncState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch UploadDetailsCopy.activityIndicator(for: state) {
            case .inProgress(let current, let total):
                UploadProgressRing(current: current, total: total)
            case .waitingForWiFi:
                Image(systemName: "pause.circle")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
            case .hidden:
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(Color.black.opacity(0.45), in: Circle())
        // One element. The ring and its backing otherwise both carry the
        // identifier, and a tap cannot choose between them.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("uploadProgressButton")
        .accessibilityLabel(UploadDetailsCopy.accessibilityLabel(for: state))
    }
}

// A ring with a real size. A toolbar ProgressView collapses, and the
// timeline's light bar treatment would paint a spinner white on photos.
private struct UploadProgressRing: View {
    var current: Int
    var total: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 2)
            if total > 0 {
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(current) / CGFloat(max(total, 1))))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .frame(width: 16, height: 16)
    }
}

// Offers upload above a timeline that already has photos. The empty
// timeline has its own button, so this stays dismissible.
struct UploadEnableBanner: View {
    var onEnable: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Enable upload", action: onEnable)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("enableUploadButton")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("enableUploadDismissButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("enableUploadBanner")
    }
}
