//
//  RepositorySettingsView.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import SwiftUI
import LibGit2

// Displays repository information and git operations for development purposes.
// Provides access to git plumbing operations like push, pull, and status checking.

struct RepositorySettingsView: View {
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var repoPath: String = ""
    @State private var currentBranch: String = "Unknown"
    @State private var lfsUrl: String = ""
    @State private var gitOriginUrl: String = ""
    @State private var originUrlDraft: String = ""
    @State private var gitStatus: String = ""
    @State private var isPulling = false
    @State private var isCheckingStatus = false
    @State private var pullProgress: Double = 0.0
    @State private var pullProgressMessage: String = ""
    @State private var timelineItemCountText: String = "Timeline items: --"
    
    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                        .font(.system(size: 60))
                    
                    Text("libgit2 Integration")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    if let error = errorMessage {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    
                    if let success = successMessage {
                        Text(success)
                            .foregroundColor(.green)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    
                    Divider()
                        .padding(.vertical)
                    
                    VStack(spacing: 15) {
                        Text("Repository cloned at:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(repoPath)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        Text("Current branch: \(currentBranch)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 5)
                        
                        Text("Git origin: \(gitOriginUrl)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)

                        Text(timelineItemCountText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Change origin URL")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("https://…", text: $originUrlDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                                .font(.caption2)
                                .textFieldStyle(.roundedBorder)

                            Button(action: applyOriginURLChange) {
                                Label("Apply origin URL", systemImage: "link")
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.gray.opacity(0.2))
                                    .foregroundColor(.primary)
                                    .cornerRadius(10)
                            }
                            .disabled(originUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.horizontal)
                        
                        Text("LFS URL: \(lfsUrl)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Button(action: pushToRemote) {
                            Label("Push to Remote", systemImage: "arrow.up.doc")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.horizontal)
                        
                        VStack(spacing: 8) {
                            Button(action: pullRebase) {
                                HStack {
                                    if isPulling {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.8)
                                    }
                                    Label(isPulling ? "Pulling..." : "Pull with Rebase", systemImage: "arrow.down.doc")
                                }
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(isPulling ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(isPulling)
                            
                            if isPulling {
                                VStack(spacing: 4) {
                                    ProgressView(value: pullProgress, total: 100)
                                        .progressViewStyle(LinearProgressViewStyle())
                                    
                                    Text(pullProgressMessage)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Git Status")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: refreshStatus) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .disabled(isCheckingStatus)
                }
                
                ScrollView {
                    if isCheckingStatus {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Fetching and checking status...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(gitStatus.isEmpty ? "No status yet" : gitStatus)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Repository")
        .task {
            checkRepositoryStatus()
        }
    }
    
    // Loads current repository metadata so the settings screen reflects the repo's actual on-disk state.
    // Fetches from remote to ensure ahead/behind comparisons are accurate.
    private func checkRepositoryStatus() {
        log("checkRepositoryStatus() starting...", context: "UI")
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        let repoDir = RepositoryManager.shared.repositoryPath()
        repoPath = repoDir
        
        guard Repository.exists(at: repoDir) else { return }
        let lfs = ServerConfigurationManager.shared.loadLFSURL() ?? ""
        isCheckingStatus = true
        
        Task {
            defer { isCheckingStatus = false }
            do {
                let snapshot = try await fetchStatusSnapshot(repoDir: repoDir, fetchLogContext: "initial status check")
                
                currentBranch = snapshot.branch
                lfsUrl = lfs
                gitOriginUrl = snapshot.remoteUrl ?? "No remote configured"
                originUrlDraft = snapshot.remoteUrl ?? ""
                gitStatus = snapshot.status
                await loadTimelineItemCount()
                
                let totalDuration = CFAbsoluteTimeGetCurrent() - totalStartTime
                log("checkRepositoryStatus() completed in \(String(format: "%.3f", totalDuration))s", context: "UI")
                log("Current branch: \(snapshot.branch)", context: "UI")
                log("LFS URL: \(lfs)", context: "UI")
                log("Git origin URL: \(snapshot.remoteUrl ?? "none")", context: "UI")
            } catch {
                logError("Failed to check repository status: \(error.localizedDescription)", context: "UI")
                gitStatus = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    // Refreshes the live git status/remote info so users can confirm changes (like updating origin) took effect.
    // Fetches from remote first to ensure ahead/behind comparisons are accurate.
    private func refreshStatus() {
        guard !isCheckingStatus else { return }
        let repoDir = RepositoryManager.shared.repositoryPath()
        guard Repository.exists(at: repoDir) else { return }
        isCheckingStatus = true
        
        Task {
            defer { isCheckingStatus = false }
            do {
                let snapshot = try await fetchStatusSnapshot(repoDir: repoDir, fetchLogContext: "status refresh")
                gitStatus = snapshot.status
                currentBranch = snapshot.branch
                lfsUrl = ServerConfigurationManager.shared.loadLFSURL() ?? ""
                gitOriginUrl = snapshot.remoteUrl ?? "No remote configured"
                originUrlDraft = snapshot.remoteUrl ?? ""
                await loadTimelineItemCount()
                
                log("Refreshed git status", context: "UI")
            } catch {
                logError("Failed to refresh status: \(error.localizedDescription)", context: "UI")
                gitStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    // Runs blocking fetch + status work off the main thread while preserving "fetch before status".
    private func fetchStatusSnapshot(repoDir: String, fetchLogContext: String) async throws -> (branch: String, remoteUrl: String?, status: String) {
        try await Task.detached(priority: .userInitiated) {
            log("Opening repository...", context: "UI")
            let repo = try Repository(path: repoDir)
            
            do {
                try repo.fetch(remoteName: "origin")
                log("Fetched from remote during \(fetchLogContext)", context: "UI")
            } catch {
                logWarning("Failed to fetch during \(fetchLogContext): \(error.localizedDescription)", context: "UI")
            }
            
            let branch = repo.currentBranch() ?? "No commits yet"
            let remoteUrl = repo.getRemoteUrl()
            let status = repo.getStatus()
            return (branch, remoteUrl, status)
        }.value
    }

    // Applies a user-provided origin URL so repository operations and mTLS HTTP requests target the same server.
    private func applyOriginURLChange() {
        errorMessage = nil
        successMessage = nil

        let trimmed = originUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed) != nil else {
            errorMessage = "Invalid URL"
            return
        }

        do {
            let repo = try RepositoryManager.shared.getRepository()
            try repo.addRemote(name: "origin", url: trimmed)
            try ServerConfigurationManager.shared.updateServerURL(trimmed)
            gitOriginUrl = repo.getRemoteUrl() ?? trimmed
            successMessage = "Updated origin URL"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Performs a push using libgit2's native push with mTLS transport (ADR-0010).
    // libgit2 handles pack negotiation, packfile creation, and report-status parsing.
    private func pushToRemote() {
        log("Pushing to remote (via libgit2 mTLS transport)...", context: "UI")
        errorMessage = nil
        successMessage = nil
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        Task {
            do {
                // Ensure mTLS transport is configured before push
                try ensureMTLSTransportConfigured()
                
                let repo = try RepositoryManager.shared.getRepository()
                let branchName = repo.currentBranch() ?? "main"
                
                log("Pushing branch: \(branchName)", context: "UI")
                
                // libgit2's push handles everything: negotiation, pack creation, error handling
                try repo.push(remoteName: "origin", branchName: branchName)
                
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                
                let updatedStatus = repo.getStatus()
                
                await MainActor.run {
                    gitStatus = updatedStatus
                    successMessage = "Pushed \(branchName) to remote successfully! (\(String(format: "%.2f", duration))s)"
                }
                log("Push completed successfully in \(String(format: "%.3f", duration)) seconds", context: "UI")
            } catch {
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                logError("Failed to push to remote after \(String(format: "%.3f", duration)) seconds: \(error.localizedDescription)", context: "UI")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    // Performs a pull using libgit2's native pullRebase with mTLS transport (ADR-0010).
    // libgit2 handles fetch negotiation, packfile import, and rebase.
    private func pullRebase() {
        log("Pulling with rebase from remote (via libgit2 mTLS transport)...", context: "UI")
        errorMessage = nil
        successMessage = nil
        isPulling = true
        pullProgress = 0.0
        pullProgressMessage = "Connecting to server..."
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        Task {
            do {
                // Ensure mTLS transport is configured before pull
                try ensureMTLSTransportConfigured()
                
                let repo = try RepositoryManager.shared.getRepository()
                let gitDB = try GitDBManager.shared.getGitDB()
                let branchName = repo.currentBranch() ?? "main"
                
                log("Pulling branch: \(branchName)", context: "UI")
                
                await MainActor.run {
                    pullProgressMessage = "Fetching and rebasing..."
                    pullProgress = 30.0
                }
                
                // Pull and SQL sync are enforced together by GitDB.
                try await gitDB.pull(remoteName: "origin", branchName: branchName) { phase, loaded, total in
                    Task { @MainActor in
                        self.pullProgressMessage = phase
                        if total > 0 {
                            let hydrationProgress = Double(loaded) / Double(total)
                            self.pullProgress = max(self.pullProgress, 70.0 + (hydrationProgress * 30.0))
                        }
                    }
                }
                log("GitDB pull completed with SQL synchronization", context: "UI")
                
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                
                let updatedBranch = repo.currentBranch() ?? "Unknown"
                let updatedStatus = repo.getStatus()
                
                await MainActor.run {
                    currentBranch = updatedBranch
                    gitStatus = updatedStatus
                    successMessage = "Pulled successfully! (\(String(format: "%.2f", duration))s)"
                    isPulling = false
                    pullProgress = 100.0
                }
                await loadTimelineItemCount()
                log("Pull completed successfully in \(String(format: "%.3f", duration)) seconds", context: "UI")
                
            } catch {
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                logError("Failed to pull after \(String(format: "%.3f", duration)) seconds: \(error.localizedDescription)", context: "UI")
                
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isPulling = false
                }
            }
        }
    }

    // Loads timeline-visible item count from the shared manifest cache so settings can show repository scale.
    private func loadTimelineItemCount() async {
        do {
            let database = try ManifestLoaderManager.shared.getDatabase()
            let table = try await database.tableName(for: OriginalManifest.self)
            let count = try await database.queryCount(sql: """
                SELECT COUNT(*)
                FROM \(table)
                WHERE guessedTakenAt IS NOT NULL
            """)
            timelineItemCountText = "Timeline items: \(count)"
        } catch {
            timelineItemCountText = "Timeline items: unavailable"
            logWarning("Failed to load timeline item count: \(error.localizedDescription)", context: "UI")
        }
    }
    
    // Ensures the mTLS transport is registered with libgit2 before network operations.
    // This handles cases where the transport wasn't configured at app launch.
    private func ensureMTLSTransportConfigured() throws {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw MTLSTransportError.notConfigured
        }
        
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
    }
}


