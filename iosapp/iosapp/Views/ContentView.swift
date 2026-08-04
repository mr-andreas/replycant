//
//  ContentView.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import SwiftUI
import LibGit2
import UIKit

// Chooses onboarding vs main app flow based on repository readiness and persisted credentials.
struct ContentView: View {
    // Carries preview-only UI state so Canvas renders deterministic app-flow snapshots without runtime setup.
    struct PreviewState {
        let errorMessage: String?
        let isRepoInitialized: Bool
        let selectedTab: Int
        let isResyncing: Bool
        let resyncProgress: Double
        let resyncProgressMessage: String
    }

    private let previewState: PreviewState?
    @State private var errorMessage: String?
    @State private var isRepoInitialized = false
    @State private var selectedTab = 0
    @State private var isResyncing = false
    @State private var resyncProgress: Double = 0
    @State private var resyncProgressMessage: String = "Preparing resync..."
    @State private var hasEmittedRootVisible = false
    @State private var hasEmittedMainTabsVisible = false
    @State private var hasEmittedOnboardingVisible = false

    // Allows previews to inject mocked state and skip expensive startup dependencies.
    init(previewState: PreviewState? = nil) {
        self.previewState = previewState
        _errorMessage = State(initialValue: previewState?.errorMessage)
        _isRepoInitialized = State(initialValue: previewState?.isRepoInitialized ?? false)
        _selectedTab = State(initialValue: previewState?.selectedTab ?? 0)
        _isResyncing = State(initialValue: previewState?.isResyncing ?? false)
        _resyncProgress = State(initialValue: previewState?.resyncProgress ?? 0)
        _resyncProgressMessage = State(initialValue: previewState?.resyncProgressMessage ?? "Preparing resync...")
    }
    
    // Gates onboarding skips to explicit developer overrides so simulator installs follow the normal app flow.
    private var shouldSkipOnboarding: Bool {
        Self.shouldSkipOnboarding(environment: ProcessInfo.processInfo.environment)
    }

    // Shows main tabs only after a local repository is available or onboarding is explicitly skipped.
    private var shouldShowMainTabs: Bool {
        return isRepoInitialized || shouldSkipOnboarding
    }

    // Enables automatic full re-clone when local repository state is missing but secure credentials/config still exist.
    private var canAutoResync: Bool {
        Self.shouldAutoResync(
            isRepoInitialized: isRepoInitialized,
            shouldSkipOnboarding: shouldSkipOnboarding,
            isConfigured: ServerConfigurationManager.shared.isConfigured,
            hasIdentity: ClientIdentityManager.shared.hasIdentity()
        )
    }
    
    var body: some View {
        Group {
            if isResyncing {
                resyncView
            } else if shouldShowMainTabs {
                TabView(selection: $selectedTab) {
                    TimelineView()
                        .tabItem {
                            Label("Timeline", systemImage: "clock")
                        }
                        .tag(0)
                        .accessibilityIdentifier("timelineTab")
                    
                    PhotoSyncView()
                        .tabItem {
                            Label("Upload", systemImage: "photo.on.rectangle.angled")
                        }
                        .tag(1)
                        .accessibilityIdentifier("uploadTab")
                    
                    SettingsView(onWipeAndResync: {
                        Task { await performResync(shouldWipeLocalState: true) }
                    })
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(2)
                        .accessibilityIdentifier("settingsTab")
                }
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .onAppear {
                    emitMainTabsVisibleIfNeeded()
                }
            } else if canAutoResync {
                VStack(spacing: 12) {
                    Text("Local data was reset")
                        .font(.headline)
                    Text("Tap retry to clone fresh state from the server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Button("Retry Resync") {
                        Task { await performResync(shouldWipeLocalState: false) }
                    }
                }
            } else {
                OnboardingView(onComplete: {
                    checkRepositoryStatus()
                    errorMessage = nil
                })
                .onAppear {
                    emitOnboardingVisibleIfNeeded()
                }
            }
        }
        .onAppear {
            emitRootVisibleIfNeeded()
        }
        .task {
            guard previewState == nil else { return }
            await initializeRepositoryState()
        }
        .task(id: shouldShowMainTabs && !isResyncing) {
            guard previewState == nil else { return }
            updatePeriodicSyncLifecycle()
        }
    }
    
    // Initializes git and repository availability before the UI decides which flow to render.
    private func initializeRepositoryState() async {
        let initStateSignpost = AppSignposts.begin("ContentInitializeRepositoryState")
        defer {
            AppSignposts.end("ContentInitializeRepositoryState", initStateSignpost)
        }

        errorMessage = nil

        let gitInitStartTime = CFAbsoluteTimeGetCurrent()
        let gitInitSignpost = AppSignposts.begin("GitInitialize")
        do {
            log("Starting Git.initialize()...", context: "Git")
            try Git.initialize()
            AppSignposts.end("GitInitialize", gitInitSignpost)
            let gitInitEndTime = CFAbsoluteTimeGetCurrent()
            let gitInitDuration = gitInitEndTime - gitInitStartTime
            log("Git.initialize() completed in \(String(format: "%.3f", gitInitDuration)) seconds", context: "Git")

            checkRepositoryStatus()
            if canAutoResync {
                await performResync(shouldWipeLocalState: false)
            }
        } catch {
            AppSignposts.end("GitInitialize", gitInitSignpost)
            let gitInitEndTime = CFAbsoluteTimeGetCurrent()
            let gitInitDuration = gitInitEndTime - gitInitStartTime
            logError("Initialization failed after \(String(format: "%.3f", gitInitDuration)) seconds: \(error.localizedDescription)", context: "Git")
            errorMessage = error.localizedDescription
            checkRepositoryStatus()
        }
    }

    // Re-checks local repository presence so view flow follows actual on-disk state.
    private func checkRepositoryStatus() {
        let repoDir = RepositoryManager.shared.repositoryPath()
        isRepoInitialized = Repository.exists(at: repoDir)
        AppSignposts.event("RepositoryStatusChecked")
    }

    // Shows progress while rebuilding local git state from server after a wipe.
    private var resyncView: some View {
        VStack(spacing: 30) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(1.5)
                .padding()

            Text(resyncProgressMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 4) {
                ProgressView(value: resyncProgress, total: 100)
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding(.horizontal, 40)

                Text("\(Int(resyncProgress))% complete")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // Rebuilds local state by optionally wiping local repo state first, then cloning from origin without onboarding.
    private func performResync(shouldWipeLocalState: Bool) async {
        if !shouldWipeLocalState {
            guard canAutoResync else { return }
        }
        PeriodicSyncManager.shared.stop()
        isResyncing = true
        // Keeps long clone/index work alive by preventing iOS idle auto-lock.
        UIApplication.shared.isIdleTimerDisabled = true
        resyncProgress = 0
        resyncProgressMessage = shouldWipeLocalState ? "Resetting local state..." : "Configuring secure transport..."
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isResyncing = false
            updatePeriodicSyncLifecycle()
        }

        do {
            if shouldWipeLocalState {
                let repoPath = RepositoryManager.shared.repositoryPath()
                resyncProgressMessage = "Deleting local data..."
                try await StateResetManager.shared.wipeLocalStateKeepingKeys(repositoryPath: repoPath) { fraction in
                    let clampedFraction = min(max(fraction, 0), 1)
                    Task { @MainActor in
                        self.resyncProgress = clampedFraction * 18
                    }
                }
                checkRepositoryStatus()
                resyncProgress = 18
                resyncProgressMessage = "Configuring secure transport..."
            }

            guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
                  let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
                throw MTLSTransportError.notConfigured
            }
            try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
            resyncProgress = max(resyncProgress, 20)

            guard let serverURL = ServerConfigurationManager.shared.loadURL() else {
                throw ContentViewResyncError.missingServerURL
            }

            let repoPath = RepositoryManager.shared.repositoryPath()
            let mtlsURL = MTLSTransport.convertToMTLSScheme(serverURL)
            resyncProgress = 20
            resyncProgressMessage = "Cloning from server..."

            _ = try await Task.detached {
                try Repository.clone(from: mtlsURL, to: repoPath, depth: 1) { gitProgress in
                    Task { @MainActor in
                        self.resyncProgress = 20 + (gitProgress.percentage * 0.6)
                        self.resyncProgressMessage = "Cloning: " + gitProgress.description
                    }
                }
            }.value

            RepositoryManager.shared.clearRepository()
            GitDBManager.shared.clearGitDB()
            try ManifestLoaderManager.shared.deleteDatabaseFile()
            resyncProgress = 80
            resyncProgressMessage = "Building media index..."

            let gitDB = try GitDBManager.shared.getGitDB()
            try await gitDB.syncToHead { phase, loaded, total in
                let fraction = total > 0 ? Double(loaded) / Double(total) : 0
                Task { @MainActor in
                    self.resyncProgress = 80 + (fraction * 19)
                    self.resyncProgressMessage = "\(phase) (\(loaded)/\(total))"
                }
            }

            checkRepositoryStatus()
            resyncProgress = 100
            resyncProgressMessage = "Resync complete"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Isolates onboarding skip decisions so tests can verify simulator installs do not bypass onboarding implicitly.
    static func shouldSkipOnboarding(environment: [String: String]) -> Bool {
        environment["SKIP_ONBOARDING"] == "1"
    }

    // Encodes when a missing repository should auto-clone from server credentials instead of showing onboarding.
    static func shouldAutoResync(
        isRepoInitialized: Bool,
        shouldSkipOnboarding: Bool,
        isConfigured: Bool,
        hasIdentity: Bool
    ) -> Bool {
        if shouldSkipOnboarding || isRepoInitialized {
            return false
        }
        return isConfigured && hasIdentity
    }

    // Keeps periodic sync active only while the main authenticated tab flow is visible.
    private func updatePeriodicSyncLifecycle() {
        if shouldShowMainTabs && !isResyncing {
            // Flushes upload cache only after a server-confirmed push to avoid caching rolled-back local commits.
            PeriodicSyncManager.shared.onPushSuccess = {
                Task { @MainActor in
                    UploadedMediaCache.shared.flushPending()
                }
            }
            PeriodicSyncManager.shared.start()
        } else {
            PeriodicSyncManager.shared.onPushSuccess = nil
            PeriodicSyncManager.shared.stop()
        }
    }

    // Emits one startup marker when the root app shell first appears on screen.
    private func emitRootVisibleIfNeeded() {
        guard !hasEmittedRootVisible else { return }
        hasEmittedRootVisible = true
        AppSignposts.event("RootContentVisible")
    }

    // Emits one startup marker when the main tabs become visible for the first time.
    private func emitMainTabsVisibleIfNeeded() {
        guard !hasEmittedMainTabsVisible else { return }
        hasEmittedMainTabsVisible = true
        AppSignposts.event("MainTabsVisible")
    }

    // Emits one startup marker when onboarding is the first visible screen.
    private func emitOnboardingVisibleIfNeeded() {
        guard !hasEmittedOnboardingVisible else { return }
        hasEmittedOnboardingVisible = true
        AppSignposts.event("OnboardingVisible")
    }
}

// Represents resync-specific failures so ContentView can report actionable errors without onboarding dependencies.
private enum ContentViewResyncError: LocalizedError {
    case missingServerURL

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "Server URL not configured"
        }
    }
}

#Preview {
    ContentView(
        previewState: .init(
            errorMessage: nil,
            isRepoInitialized: true,
            selectedTab: 0,
            isResyncing: false,
            resyncProgress: 0,
            resyncProgressMessage: "Preparing resync..."
        )
    )
}

#Preview("Resync Progress") {
    ContentView(
        previewState: .init(
            errorMessage: nil,
            isRepoInitialized: false,
            selectedTab: 0,
            isResyncing: true,
            resyncProgress: 63,
            resyncProgressMessage: "Building media index... (1260/2000)"
        )
    )
}
