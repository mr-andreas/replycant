import Foundation

// Coordinates simulator-only bootstrap so local debug runs use stable credentials and endpoints.
@MainActor
final class SimulatorAutoConnectManager {
    static let shared = SimulatorAutoConnectManager()

    private init() {}

    // Exposes whether simulator auto-connect behavior should be active for this build target.
    var isAutoConnectEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // Skips generated keys only when bundled credentials will replace
    // them. Recovery on a fresh simulator still needs a device key.
    static func shouldSkipGeneratedDeviceKey(
        isAutoConnectEnabled: Bool,
        hasBundledSimulatorCredentials: Bool
    ) -> Bool {
        isAutoConnectEnabled && hasBundledSimulatorCredentials
    }

    // Prepares keychain identity and server configuration early enough for mTLS transport setup.
    func prepareForLaunchIfNeeded() {
        guard isAutoConnectEnabled else { return }
        // Screenshot onboarding captures also need a clean first-run path without
        // bundled simulator credentials re-applying after TestSupport wipes state.
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let hasIntegrationControlEndpoint = !(environment["REPLYCANT_INTEGRATION_CTL"] ?? "").isEmpty
        guard !arguments.contains("--uitesting"),
              !arguments.contains("--screenshots-onboarding"),
              !hasIntegrationControlEndpoint else {
            log("Skipping simulator auto-connect during UI tests", context: "SimAutoConnect")
            return
        }

        var identityImportError: Error?
        var serverConfigError: Error?

        do {
            try ClientIdentityManager.shared.importBundledSimulatorIdentityIfNeeded()
        } catch {
            identityImportError = error
            logError("Simulator identity prep failed: \(error.localizedDescription)", context: "SimAutoConnect")
        }

        do {
            try ServerConfigurationManager.shared.applyBundledSimulatorConfigurationIfNeeded()
        } catch {
            serverConfigError = error
            logError("Simulator server config prep failed: \(error.localizedDescription)", context: "SimAutoConnect")
        }

        if identityImportError == nil && serverConfigError == nil {
            log("Simulator auto-connect launch prep complete", context: "SimAutoConnect")
        } else if let identityImportError, let serverConfigError {
            logError(
                "Simulator launch prep completed with both failures: identity=\(identityImportError.localizedDescription), serverConfig=\(serverConfigError.localizedDescription)",
                context: "SimAutoConnect"
            )
        }
    }
}
