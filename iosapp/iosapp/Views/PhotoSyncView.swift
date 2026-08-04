import SwiftUI

struct PhotoSyncView: View {
    @StateObject private var syncManager: PhotoSyncManager

    init(syncManager: PhotoSyncManager? = nil) {
        if let manager = syncManager {
            _syncManager = StateObject(wrappedValue: manager)
        } else {
            _syncManager = StateObject(wrappedValue: PhotoSyncManager())
        }
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
            
            if !isActivelySyncing {
                Button(action: {
                    Task {
                        await syncManager.startSync()
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
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding(.horizontal)
                
                Text("Uploading \(current) of \(total)")
                    .font(.headline)
                
                Text(currentFile)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
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

