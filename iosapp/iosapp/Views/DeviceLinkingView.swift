import SwiftUI
import LibGit2

// Handles the Device A side of device linking: scan new device's public key, grant it access, and display connection QR.
// This allows an existing configured device to authorize a new device by adding its public key to the pubkeys/ directory.
struct DeviceLinkingView: View {
    @Environment(\.dismiss) private var dismiss
    static let scanPublicKeyHeading = "Scan the new device's QR code"
    static let shareConfigSuccessLabel = "Access granted!"
    static let shareConfigHeading = "Now let the new device scan this"
    static let shareConfigBody = "On the new device, tap Next and point its camera at this code"
    
    @State private var currentStep: LinkingStep
    @State private var isProcessing: Bool
    @State private var errorMessage: String?
    @State private var progressMessage: String
    @State private var scannedDeviceName: String
    @State private var scannedDeviceUUID: String
    @State private var scannedPublicKey: String
    @State private var scannedAgePublicKey: String
    @State private var showScanner: Bool
    @State private var showInvalidQRCodeAlert: Bool
    @State private var invalidQRCodeMessage: String
    private let previewConfigJSON: String?

    init() {
        _currentStep = State(initialValue: .scanPublicKey)
        _isProcessing = State(initialValue: false)
        _progressMessage = State(initialValue: "")
        _scannedDeviceName = State(initialValue: "")
        _scannedDeviceUUID = State(initialValue: "")
        _scannedPublicKey = State(initialValue: "")
        _scannedAgePublicKey = State(initialValue: "")
        _showScanner = State(initialValue: false)
        _showInvalidQRCodeAlert = State(initialValue: false)
        _invalidQRCodeMessage = State(initialValue: "Unsupported QR code format. Expected a device-link QR with pubkey, age_pubkey, name, and uuid.")
        self.previewConfigJSON = nil
    }

    /// Preview-only initializer that parks the view at a specific step
    /// with sample data, avoiding any singleton or camera access.
    init(
        preview step: LinkingStep,
        isProcessing: Bool = false,
        progressMessage: String = "",
        errorMessage: String? = nil,
        scannedDeviceName: String = "preview-iphone",
        configJSON: String? = nil
    ) {
        _currentStep = State(initialValue: step)
        _isProcessing = State(initialValue: isProcessing)
        _progressMessage = State(initialValue: progressMessage)
        _errorMessage = State(initialValue: errorMessage)
        _scannedDeviceName = State(initialValue: scannedDeviceName)
        _scannedDeviceUUID = State(initialValue: "preview-uuid")
        _scannedPublicKey = State(initialValue: "")
        _scannedAgePublicKey = State(initialValue: "")
        _showScanner = State(initialValue: false)
        _showInvalidQRCodeAlert = State(initialValue: false)
        _invalidQRCodeMessage = State(initialValue: "")
        self.previewConfigJSON = configJSON
    }
    
    var body: some View {
        Group {
            switch currentStep {
            case .scanPublicKey:
                scanPublicKeyView
            case .processing:
                processingView
            case .showConfig:
                showConfigView
            case .error:
                errorView
            }
        }
        .navigationTitle(currentStep.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(currentStep == .showConfig)
        .alert("Invalid QR Code", isPresented: $showInvalidQRCodeAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(invalidQRCodeMessage)
        }
    }
    
    // MARK: - Scan Public Key View
    
    private var scanPublicKeyView: some View {
        VStack(spacing: 24) {
            Spacer()

            PairingStepIndicator(step: 1, phase: .sendKey)

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 70))
                .foregroundStyle(Color.brandGradient)

            Text(Self.scanPublicKeyHeading)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Scan the QR code displayed on the new device to grant it access.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            Spacer()

            Button(action: { showScanner = true }) {
                HStack {
                    Image(systemName: "camera")
                    Text("Scan QR Code")
                }
            }
            .buttonStyle(PairingPrimaryButtonStyle())
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showScanner) {
            QRCodeScannerView(
                onDevicePublicKeyScan: handlePublicKeyScanned,
                onCancel: { showScanner = false },
                onInvalidScan: { message in
                    handleInvalidScan(message)
                }
            )
        }
    }
    
    // MARK: - Processing View
    
    private var processingView: some View {
        PairingProgressView(
            isProcessing: isProcessing,
            message: progressMessage
        )
    }
    
    // MARK: - Show Config View

    // Hands the new device the connection QR after access is granted,
    // completing the old-device side of pairing.
    private var showConfigView: some View {
        ScrollView {
            VStack(spacing: 16) {
                PairingStepIndicator(step: 2, of: 2, phase: .shareConfig)
                    .padding(.top, 16)

                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(Self.shareConfigSuccessLabel)
                        .fontWeight(.semibold)
                }
                .font(.title3)
                .foregroundStyle(Color.brandGreen)

                Text(Self.shareConfigHeading)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text(Self.shareConfigBody)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let configJSON = previewConfigJSON ?? buildConfigQRCode() {
                    QRCodeDisplayView(
                        data: configJSON,
                        title: "",
                        borderColor: .brandGreen
                    )
                } else {
                    Text("Failed to generate configuration QR code")
                        .foregroundColor(.red)
                }

                Button(action: { dismiss() }) {
                    Text("Done")
                }
                .buttonStyle(PairingTertiaryButtonStyle())
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }
    
    // MARK: - Error View
    
    private var errorView: some View {
        PairingErrorView(
            title: "Linking Failed",
            message: errorMessage,
            cancelLabel: "Cancel",
            onRetry: {
                currentStep = .scanPublicKey
                errorMessage = nil
            },
            onCancel: { dismiss() }
        )
    }
    
    // MARK: - QR Code Handling
    
    // Starts linking immediately from scanner-validated fields to avoid redundant JSON parsing.
    private func handlePublicKeyScanned(_ payload: QRCodeScannerView.DevicePublicKeyPayload) {
        showScanner = false
        let configuredCAHash = ServerConfigurationManager.shared.caCertificateHash()
        if !Self.isMatchingWebappCAHash(scannedCAHash: payload.caHash, configuredCAHash: configuredCAHash) {
            invalidQRCodeMessage = "You're attempting to connect to a different server than the one this app is registered with."
            showInvalidQRCodeAlert = true
            return
        }
        currentStep = .processing
        isProcessing = true
        progressMessage = "Granting access..."
        let shouldShowConfigAfterSuccess = payload.caHash == nil
        
        Task {
            do {
                await MainActor.run {
                    scannedPublicKey = payload.pubkey
                    scannedAgePublicKey = payload.agePubkey
                    scannedDeviceName = payload.name
                    scannedDeviceUUID = payload.uuid
                }
                
                try await addDeviceKeyToRepository(pubkey: payload.pubkey, agePubkey: payload.agePubkey, name: payload.name, uuid: payload.uuid)
                
                await MainActor.run {
                    isProcessing = false
                    progressMessage = "Access granted!"
                    if shouldShowConfigAfterSuccess {
                        currentStep = .showConfig
                    } else {
                        dismiss()
                    }
                }
                
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    currentStep = .error
                }
            }
        }
    }
    
    // Adds both identity keys and re-wraps KEK epochs so the new device can decrypt all existing encrypted content.
    private func addDeviceKeyToRepository(pubkey: String, agePubkey: String, name: String, uuid: String) async throws {
        updateProgress("Ensuring mTLS is configured...")
        try ensureMTLSTransportConfigured()
        
        updateProgress("Adding device key to repository...")
        let repo = try RepositoryManager.shared.getRepository()
        let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
        
        // Create key file paths with UUID suffix.
        let fileName = "\(name)-\(uuid).pub"
        let pubkeyPath = "pubkeys/\(fileName)"
        let ageFileName = "\(name)-\(uuid).age"
        let agePath = "pubkeys/\(ageFileName)"
        
        log("Adding device key: \(pubkeyPath)", context: "DeviceLinking")
        
        // Collect all age recipients including the newly scanned key.
        let existingRecipientAgePubkeys = try loadAgeRecipientKeys(repository: repo)
        let allRecipientAgePubkeys = Array(Set(existingRecipientAgePubkeys + [agePubkey]))
        let epochFiles = try KEKEpochManager(repository: repo).rewrappedEpochFilesIncludingRecipients(allRecipientAgePubkeys)

        // Create commit with both key files and re-wrapped epochs.
        var files: [(path: String, content: String)] = [
            (path: pubkeyPath, content: pubkey),
            (path: agePath, content: agePubkey)
        ]
        files.append(contentsOf: epochFiles)
        try await gitDB.commitFiles(
            message: "Add device key for \(name) (\(uuid))",
            files: files
        )
        
        updateProgress("Pushing to server...")
        let branchName = repo.currentBranch() ?? "main"
        try repo.push(remoteName: "origin", branchName: branchName)
        
        log("Successfully added and pushed device key", context: "DeviceLinking")
    }

    // Loads repository age public keys so epoch re-wrap includes every currently authorized device.
    private func loadAgeRecipientKeys(repository: Repository) throws -> [String] {
        let files = try repository.listFiles(in: "pubkeys")
        let ageFiles = files.filter { $0.hasSuffix(".age") }
        return try ageFiles.map { try repository.readFile(at: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    
    // Builds the configuration QR code JSON containing server URL and CA certificate.
    private func buildConfigQRCode() -> String? {
        guard let config = ServerConfigurationManager.shared.loadConfiguration() else {
            logError("No server configuration found", context: "DeviceLinking")
            return nil
        }
        
        let json: [String: String] = [
            "url": config.url,
            "ca": config.caCertificate
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logError("Failed to serialize config JSON", context: "DeviceLinking")
            return nil
        }
        
        return jsonString
    }

    // Ensures the mTLS transport is registered with libgit2 before network operations.
    private func ensureMTLSTransportConfigured() throws {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw LinkingError.noMTLSCredentials
        }
        
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
    }
    
    @MainActor
    // Updates progress text on the main actor so linking state changes render consistently.
    private func updateProgress(_ message: String) {
        progressMessage = message
    }

    // Presents an invalid-QR alert and exits scanner flow to prevent ambiguous retry states.
    @MainActor
    private func handleInvalidScan(_ message: String) {
        showScanner = false
        invalidQRCodeMessage = message
        showInvalidQRCodeAlert = true
    }

}

// MARK: - Supporting Types

enum LinkingStep {
    case scanPublicKey
    case processing
    case showConfig
    case error
    
    var title: String {
        switch self {
        case .scanPublicKey: return "Link Device"
        case .processing: return "Granting Access"
        case .showConfig: return ""
        case .error: return "Error"
        }
    }
}

private enum LinkingError: Error, LocalizedError {
    case noMTLSCredentials
    
    // Provides actionable user-facing errors when linking cannot proceed.
    var errorDescription: String? {
        switch self {
        case .noMTLSCredentials:
            return "mTLS credentials not configured. Please complete initial setup first."
        }
    }
}

extension DeviceLinkingView {
    // Compares optional scanned and configured hashes so webapp linking only succeeds for the same trusted server.
    static func isMatchingWebappCAHash(scannedCAHash: String?, configuredCAHash: String?) -> Bool {
        guard let scannedCAHash else {
            return true
        }
        guard let configuredCAHash else {
            return false
        }
        return configuredCAHash.caseInsensitiveCompare(scannedCAHash) == .orderedSame
    }
}

#Preview("Scan Public Key") {
    NavigationStack {
        DeviceLinkingView()
    }
}

#Preview("Processing") {
    NavigationStack {
        DeviceLinkingView(
            preview: .processing,
            isProcessing: true,
            progressMessage: "Adding device key..."
        )
    }
}

#Preview("Show Config") {
    NavigationStack {
        DeviceLinkingView(
            preview: .showConfig,
            scannedDeviceName: "preview-iphone",
            configJSON: "{\"url\":\"https://git.example.com\",\"ca\":\"-----BEGIN CERTIFICATE-----\\nMIIB...\\n-----END CERTIFICATE-----\"}"
        )
    }
}

#Preview("Error") {
    NavigationStack {
        DeviceLinkingView(
            preview: .error,
            errorMessage: "mTLS credentials not configured. Please complete initial setup first."
        )
    }
}
