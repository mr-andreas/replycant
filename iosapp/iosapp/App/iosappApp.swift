//
//  iosappApp.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import SwiftUI
import LibGit2
import UserNotifications

@main
struct iosappApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Runs launch-time setup so simulator debug sessions can connect immediately without QR onboarding.
    init() {
        // Installed before the preview return so git and identity lines
        // from later launch work are in the file Settings can share.
        diagnosticLogSink = { ApplicationLog.append($0) }

        // Canvas hosts the real app process; skip launch I/O so #Preview
        // does not clone the library or trip libgit2/keychain setup.
        if ContentView.isRunningForPreviews(environment: ProcessInfo.processInfo.environment) {
            return
        }
        #if DEBUG
        if AppScreenGallery.shouldShowGallery(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            return
        }
        #endif

        let appInitSignpost = AppSignposts.begin("AppInit")
        defer {
            AppSignposts.end("AppInit", appInitSignpost)
        }

        // The monitor has to be running before the first video or upload,
        // so the mobile-data decision is ready when the user acts.
        _ = NetworkCostMonitor.shared

        // Registration has to finish during launch or iOS will not run the
        // charging upload, including a launch that exists only for that task.
        BackgroundUploadScheduler.shared.register()
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared

        // Keeps UITest-only setup code out of Release/App Store builds.
        #if DEBUG
        TestSupport.setupTestEnvironment()
        #endif

        // Preloads simulator debug credentials/configuration so startup uses stable local assets.
        SimulatorAutoConnectManager.shared.prepareForLaunchIfNeeded()
        
        // Generate device key on first boot (idempotent - does nothing if key exists).
        // This ensures the key exists before any onboarding flow needs it.
        // UI tests create the test-device identity inside deferred fixture
        // setup. Doing it here as well races that write on the keychain.
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--uitesting") {
            ensureDeviceKeyExists()
        }
        #else
        ensureDeviceKeyExists()
        #endif
        
        // Initialize mTLS transport for Git network operations if credentials are available.
        // This registers the mtls+https:// scheme with libgit2, enabling push/pull
        // with client certificate authentication.
        initializeMTLSTransport()
        startTailnetJoin()

        // Rebuild disk cache indices from previous sessions so
        // cached thumbnails and originals are available immediately.
        Task {
            let cache = ImageDiskCacheManager.shared
            await cache.rebuild()
            await cache.startObservingSettings()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if AppScreenGallery.shouldShowGallery(
                arguments: ProcessInfo.processInfo.arguments
            ) {
                ScrollView([.horizontal, .vertical]) {
                    AppScreenGalleryBoard(
                        screens: AppScreenGallery.all,
                        columns: 4
                    )
                }
            } else {
                contentRoot
            }
            #else
            contentRoot
            #endif
        }
    }

    // Keeps the production root in one place so the debug gallery
    // host can replace it without duplicating the deep-link hook.
    private var contentRoot: some View {
        ContentView()
            .onOpenURL { url in
                RecoveryDeepLinkRouter.shared.handle(url: url)
                #if DEBUG
                DebugBootstrapLinkRouter.shared.handle(url: url)
                DebugDeviceLinkRouter.shared.handle(url: url)
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
    }

    /// Rebuilds the tailnet node after a long lock. A quick switch to
    /// another app leaves it running; launch does not come through here
    /// with a recorded background time, so the startup join is unchanged.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Task { await TailnetBootstrap.shared.noteEnteredBackground() }
            if BackgroundUploadScheduler.shared.isEnabled {
                BackgroundUploadScheduler.shared.schedule()
            }
        case .active:
            UploadBacklogTracker.shared.refreshOverdue()
            // After the first timeline load this starts a run. Before
            // that it returns, so launch is not spent scanning Photos.
            Task { await UploadController.shared.startIfReady() }
            Task {
                do {
                    try await TailnetBootstrap.shared.noteReturnedToForeground()
                } catch TailnetBootstrap.BootstrapError.stillConnecting {
                    log("Tailnet join still in progress after wake", context: "Tailnet")
                } catch {
                    logError(
                        "Failed to restore the tailnet after wake: \(error.localizedDescription)",
                        context: "Tailnet"
                    )
                }
            }
        default:
            break
        }
    }
    
    // Creates the device key on first boot. Called exactly once per app installation.
    // After generation, the key persists in Keychain and is never regenerated.
    // This satisfies ADR-0011's requirement for immutable device identity.
    private func ensureDeviceKeyExists() {
        let signpost = AppSignposts.begin("EnsureDeviceKey")
        defer {
            AppSignposts.end("EnsureDeviceKey", signpost)
        }

        #if DEBUG && targetEnvironment(simulator)
        // Avoids generating a throwaway identity when bundled
        // SimulatorCredentials will be imported instead.
        if SimulatorAutoConnectManager.shouldSkipGeneratedDeviceKey(
            isAutoConnectEnabled: SimulatorAutoConnectManager.shared.isAutoConnectEnabled,
            hasBundledSimulatorCredentials: ClientIdentityManager.shared.hasBundledSimulatorCredentials()
        ) {
            log("Skipping generated device key because bundled simulator credentials are present", context: "App")
            return
        }
        #endif

        let deviceName = UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
        
        log("Ensuring device key exists for \(deviceName)", context: "App")
        do {
            try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: deviceName)
            log("Device key is available", context: "App")
        } catch {
            logError("Failed to generate device key: \(error.localizedDescription)", context: "App")
        }
    }
    
    // Sets up the custom mTLS transport using stored credentials from Keychain.
    private func initializeMTLSTransport() {
        let signpost = AppSignposts.begin("InitMTLSTransport")
        defer {
            AppSignposts.end("InitMTLSTransport", signpost)
        }

        log("Attempting to initialize mTLS transport...", context: "App")
        
        let identity = ClientIdentityManager.shared.loadSecIdentity()
        let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate()
        
        if identity == nil {
            log("No client identity found in Keychain", context: "App")
        }
        if pinnedCA == nil {
            log("No pinned CA certificate found", context: "App")
        }
        
        guard let identity = identity, let pinnedCA = pinnedCA else {
            log("mTLS credentials not yet available, transport will be configured after onboarding", context: "App")
            return
        }
        
        do {
            try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
            log("mTLS transport configured successfully", context: "App")
        } catch {
            logError("Failed to configure mTLS transport: \(error.localizedDescription)", context: "App")
        }
    }

    /// Starts the tailnet join before the first frame.
    ///
    /// The join waits on relay handshakes. ContentView awaits the same join
    /// and reports its outcome; starting it here overlaps that wait with
    /// SwiftUI's first render instead of beginning it afterwards. A device
    /// with nothing stored returns immediately.
    private func startTailnetJoin() {
        Task {
            try? await TailnetBootstrap.shared.ensureJoinedIfConfigured()
        }
    }
}
