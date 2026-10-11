import SwiftUI

// Handles the Device A side of device linking: scan the new device's QR and
// grant it access. Granting commits its keys to pubkeys/ and asks gitd to seal
// the new device's join record, which it picks up on its own.
struct DeviceLinkingView: View {
    @Environment(\.dismiss) private var dismiss
    static let scanPublicKeyHeading = "Scan the new device's QR code"
    
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
        _invalidQRCodeMessage = State(initialValue: "Unsupported QR code format. Expected a device-link QR with pubkey, age_pubkey, name, uuid, and pairing_secret.")
    }

    /// Preview-only initializer that parks the view at a specific step
    /// with sample data, avoiding any singleton or camera access.
    init(
        preview step: LinkingStep,
        isProcessing: Bool = false,
        progressMessage: String = "",
        errorMessage: String? = nil,
        scannedDeviceName: String = "preview-iphone"
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
    }
    
    var body: some View {
        Group {
            switch currentStep {
            case .scanPublicKey:
                scanPublicKeyView
            case .processing:
                processingView
            case .error:
                errorView
            }
        }
        .navigationTitle(currentStep.title)
        .navigationBarTitleDisplayMode(.inline)
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
        currentStep = .processing
        isProcessing = true
        progressMessage = "Granting access..."

        Task {
            do {
                await MainActor.run {
                    scannedPublicKey = payload.pubkey
                    scannedAgePublicKey = payload.agePubkey
                    scannedDeviceName = payload.name
                    scannedDeviceUUID = payload.uuid
                }

                // Grant work lives off this view so commit+push cannot
                // inherit MainActor and freeze the processing screen.
                try await DeviceLinking.grantAccess(
                    pubkey: payload.pubkey,
                    agePubkey: payload.agePubkey,
                    name: payload.name,
                    uuid: payload.uuid,
                    pairingSecret: payload.pairingSecret
                ) { message in
                    Task { @MainActor in
                        self.progressMessage = message
                    }
                }

                await MainActor.run {
                    isProcessing = false
                    progressMessage = "Access granted!"
                    dismiss()
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
    case error
    
    var title: String {
        switch self {
        case .scanPublicKey: return "Link Device"
        case .processing: return "Granting Access"
        case .error: return "Error"
        }
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

#Preview("Error") {
    NavigationStack {
        DeviceLinkingView(
            preview: .error,
            errorMessage: "mTLS credentials not configured. Please complete initial setup first."
        )
    }
}
