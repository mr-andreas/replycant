import SwiftUI
import UserNotifications

/// Copy for the upload-tab status so a 0-of-0 bar is never the only thing
/// on screen while the library is still being scanned.
enum PhotoSyncStatusCopy {
    static func headline(current: Int, total: Int, file: String) -> String {
        total == 0 ? file : "Uploading \(current) of \(total)"
    }
}

struct PhotoSyncView: View {
    @StateObject private var syncManager: PhotoSyncManager
    @ObservedObject private var backgroundUpload = BackgroundUploadScheduler.shared
    @ObservedObject private var backlog = UploadBacklogTracker.shared
    @State private var showMobileDataUploadWarning = false
    @State private var showReminderExplanation = false
    @State private var wantsBackgroundUpload = false

    init(syncManager: PhotoSyncManager? = nil) {
        let manager = syncManager ?? PhotoSyncManager.shared
        _syncManager = StateObject(wrappedValue: manager)
        _wantsBackgroundUpload = State(initialValue: BackgroundUploadScheduler.shared.isEnabled)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .font(.system(size: 60))
            
            Text("Photo Library Sync")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Sync your photos and videos to the repository")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
                .padding(.vertical)
            
            syncStatusView

            backgroundUploadToggle

            if backlog.isOverdue {
                Text("Some photos and videos have not finished uploading for 7 days. Tap Start Upload and keep the app open until it completes.")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .accessibilityIdentifier("uploadBacklogWarning")
            }
            
            if !isActivelySyncing {
                Button(action: {
                    if syncManager.isOnMeteredNetwork {
                        showMobileDataUploadWarning = true
                    } else {
                        Task {
                            await syncManager.startSync()
                        }
                    }
                }) {
                    Label("Start Upload", systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            } else {
                Button(action: {
                    syncManager.cancelSync()
                }) {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .onAppear {
            wantsBackgroundUpload = backgroundUpload.isEnabled
        }
        .onChange(of: backgroundUpload.isEnabled) { _, enabled in
            wantsBackgroundUpload = enabled
        }
        .onChange(of: wantsBackgroundUpload) { _, enabled in
            guard enabled != backgroundUpload.isEnabled else { return }
            if enabled {
                Task { await enableBackgroundUpload() }
            } else {
                Task { await backgroundUpload.setEnabled(false) }
            }
        }
        .alert("Get a reminder if uploads stall?", isPresented: $showReminderExplanation) {
            Button("Allow Reminders") {
                Task { await allowUploadReminders() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Background uploads only run while your phone is charging on Wi-Fi. If some photos and videos still have not uploaded after 7 days, Replycant can send one notification so you can finish with the app open.")
        }
        .alert("Upload over mobile data?", isPresented: $showMobileDataUploadWarning) {
            Button("Upload") {
                Task {
                    await syncManager.startSync()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos and videos upload in full original quality, which can use a lot of data.")
        }
    }
    
    // The toggle is off until the user opts in. Photo access is requested
    // while the app is open, because a charging run cannot show that prompt.
    private var backgroundUploadToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Upload automatically while charging on Wi-Fi", isOn: $wantsBackgroundUpload)
                .accessibilityIdentifier("backgroundUploadToggle")
            Text("Runs while the phone is plugged in, on Wi-Fi, and starts with the smallest files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // Turns the feature on only after photo access. The notification
    // explanation comes before iOS asks, and Not Now never asks.
    private func enableBackgroundUpload() async {
        let allowed = await syncManager.requestPhotoAccess()
        guard allowed else {
            wantsBackgroundUpload = false
            return
        }
        await backgroundUpload.setEnabled(true)
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if UploadBacklogTracker.notificationPermissionStep(status: status) == .explain {
            showReminderExplanation = true
        }
    }

    // The system prompt runs only from Allow Reminders. A refusal leaves
    // background upload on and skips the notification.
    private func allowUploadReminders() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await backlog.scheduleReminderIfArmed()
    }

    // Uses SyncState as the rendering source of truth so controls stay aligned with progress content.
    private var isActivelySyncing: Bool {
        if case .syncing = syncManager.syncState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.syncState {
        case .idle:
            Text("Ready to sync")
                .foregroundColor(.secondary)
                .padding()
        
        case .syncing(let current, let total, let currentFile, let uploadSpeed, let fileSize):
            VStack(spacing: 10) {
                if total == 0 {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    ProgressView(value: Double(current), total: Double(total))
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.horizontal)
                }

                Text(PhotoSyncStatusCopy.headline(current: current, total: total, file: currentFile))
                    .font(.headline)

                if total > 0 {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                if !fileSize.isEmpty {
                    HStack(spacing: 15) {
                        Label(fileSize, systemImage: "doc")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if !uploadSpeed.isEmpty && uploadSpeed != "Preparing..." {
                            Label(uploadSpeed, systemImage: "arrow.up.circle")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .padding()
        
        case .completed(let total):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
                
                Text("Completed!")
                    .font(.headline)
                
                Text("Uploaded \(total) files")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
        
        case .failed(let error):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.red)
                
                Text("Failed")
                    .font(.headline)
                
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

#Preview("Idle") {
    let manager = PhotoSyncManager()
    manager.syncState = .idle
    manager.isSyncing = false
    return PhotoSyncView(syncManager: manager)
}

#Preview("Syncing") {
    let manager = PhotoSyncManager()
    manager.syncState = .syncing(
        current: 7,
        total: 24,
        currentFile: "IMG_2048.HEIC",
        uploadSpeed: "6.2 MB/s",
        fileSize: "12.4 MB"
    )
    manager.isSyncing = true
    return PhotoSyncView(syncManager: manager)
}

#Preview("Completed") {
    let manager = PhotoSyncManager()
    manager.syncState = .completed(total: 24)
    manager.isSyncing = false
    return PhotoSyncView(syncManager: manager)
}

#Preview("Failed") {
    let manager = PhotoSyncManager()
    manager.syncState = .failed(NSError(domain: "Preview", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network timeout"]))
    manager.isSyncing = false
    return PhotoSyncView(syncManager: manager)
}

