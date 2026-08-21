//
//  iosappApp.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import SwiftUI
import LibGit2

@main
struct iosappApp: App {
    
    // Runs launch-time setup so simulator debug sessions can connect immediately without QR onboarding.
    init() {
        // Canvas hosts the real app process; skip launch I/O so #Preview
        // does not clone the library or trip libgit2/keychain setup.
        if ContentView.isRunningForPreviews(environment: ProcessInfo.processInfo.environment) {
            return
        }

        let appInitSignpost = AppSignposts.begin("AppInit")
        defer {
            AppSignposts.end("AppInit", appInitSignpost)
        }

        // Keeps UITest-only setup code out of Release/App Store builds.
        #if DEBUG
        TestSupport.setupTestEnvironment()
        #endif

        // Preloads simulator debug credentials/configuration so startup uses stable local assets.
        SimulatorAutoConnectManager.shared.prepareForLaunchIfNeeded()
        
        // Generate device key on first boot (idempotent - does nothing if key exists).
        // This ensures the key exists before any onboarding flow needs it.
        ensureDeviceKeyExists()
        
        // Initialize mTLS transport for Git network operations if credentials are available.
        // This registers the mtls+https:// scheme with libgit2, enabling push/pull
        // with client certificate authentication.
        initializeMTLSTransport()

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
            ContentView()
                .onOpenURL { url in
                    RecoveryDeepLinkRouter.shared.handle(url: url)
                }
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
}
