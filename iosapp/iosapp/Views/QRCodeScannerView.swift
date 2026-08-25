import SwiftUI
import AVFoundation

// Scans QR codes containing server configuration JSON for mTLS setup.
// Uses AVFoundation's metadata detection to decode {"ca": "...", "url": "..."} payloads.
// Supports multiple validation modes for different QR code formats (server config, device public key, etc.).
struct QRCodeScannerView: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let validationMode: ValidationMode
    let onInvalidScan: ((String) -> Void)?
    let onValidatedDevicePublicKey: ((DevicePublicKeyPayload) -> Void)?
    
    @State private var errorMessage: String?
    @State private var isAuthorized = false
    @State private var showPermissionDenied = false
    
    // Defines what fields are required in the scanned QR code JSON.
    enum ValidationMode {
        case serverConfig    // Requires: ca, url
        case devicePublicKey // Requires: pubkey, name, uuid
        case connectOrRecovery // Accepts server config or a recovery envelope / replycant link
        case any             // No validation, accepts any valid JSON
    }

    typealias DevicePublicKeyPayload = QRScanValidation.DevicePublicKeyPayload
    
    // Allows callers to customize invalid-scan UX while preserving existing defaults.
    init(onScan: @escaping (String) -> Void, onCancel: @escaping () -> Void, validationMode: ValidationMode = .serverConfig) {
        self.onScan = onScan
        self.onCancel = onCancel
        self.validationMode = validationMode
        self.onInvalidScan = nil
        self.onValidatedDevicePublicKey = nil
    }

    // Allows parent views to intercept invalid scan messages (for alerts, dismissal, or custom flows).
    init(
        onScan: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        validationMode: ValidationMode = .serverConfig,
        onInvalidScan: @escaping (String) -> Void
    ) {
        self.onScan = onScan
        self.onCancel = onCancel
        self.validationMode = validationMode
        self.onInvalidScan = onInvalidScan
        self.onValidatedDevicePublicKey = nil
    }

    // Specializes scanner output for device-linking so callers can avoid reparsing validated JSON.
    init(
        onDevicePublicKeyScan: @escaping (DevicePublicKeyPayload) -> Void,
        onCancel: @escaping () -> Void,
        onInvalidScan: ((String) -> Void)? = nil
    ) {
        self.onScan = { _ in }
        self.onCancel = onCancel
        self.validationMode = .devicePublicKey
        self.onInvalidScan = onInvalidScan
        self.onValidatedDevicePublicKey = onDevicePublicKeyScan
    }

    /// Preview-only initializer that bypasses camera access and parks
    /// the view in a specific visual state. The live camera state is
    /// device/simulator-only and cannot render in Xcode canvas.
    init(previewState: PreviewState) {
        self.onScan = { _ in }
        self.onCancel = {}
        self.validationMode = .any
        self.onInvalidScan = nil
        self.onValidatedDevicePublicKey = nil
        switch previewState {
        case .permissionDenied:
            _isAuthorized = State(initialValue: false)
            _showPermissionDenied = State(initialValue: true)
        case .scanning:
            _isAuthorized = State(initialValue: true)
            _showPermissionDenied = State(initialValue: false)
        case .scanError(let message):
            _isAuthorized = State(initialValue: true)
            _showPermissionDenied = State(initialValue: false)
            _errorMessage = State(initialValue: message)
        }
    }

    enum PreviewState {
        case permissionDenied
        case scanning
        case scanError(String)
    }
    
    var body: some View {
        ZStack {
            if isAuthorized {
                CameraPreviewView(onScan: handleScan)
                    .ignoresSafeArea()
                
                // Scanning overlay
                VStack {
                    Spacer()
                    
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .background(Color.clear)
                    
                    Text("Point camera at QR code")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.top, 20)
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    
                    Spacer()
                }
            } else if showPermissionDenied {
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text("Camera Access Required")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Please enable camera access in Settings to scan QR codes.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Requesting camera access...")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                }
            }
        }
        .onAppear {
            checkCameraAuthorization()
        }
    }

    // Canvas has no capture device and cannot answer a TCC prompt, so
    // previews show the scanner chrome over a placeholder instead of a
    // live session.
    static func shouldUseLiveCamera(environment: [String: String]) -> Bool {
        !ContentView.isRunningForPreviews(environment: environment)
    }
    
    // Parks Canvas on the scanning overlay instead of prompting for a
    // camera that the Previews agent cannot open.
    private func checkCameraAuthorization() {
        guard Self.shouldUseLiveCamera(
            environment: ProcessInfo.processInfo.environment
        ) else {
            isAuthorized = true
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    isAuthorized = granted
                    showPermissionDenied = !granted
                }
            }
        case .denied, .restricted:
            showPermissionDenied = true
        @unknown default:
            showPermissionDenied = true
        }
    }
    
    // Validates scanned payloads off the metadata queue and returns whether scanning should stop.
    private func handleScan(_ code: String) -> Bool {
        log("Scanned code: \(code.prefix(100))...", context: "QRScanner")
        let decision = QRScanValidation.validate(code: code, mode: validationMode)
        switch decision {
        case .reject(let message):
            DispatchQueue.main.async {
                reportValidationFailure(message)
            }
            return false
        case .acceptRaw:
            DispatchQueue.main.async {
                errorMessage = nil
                onScan(code)
            }
            return true
        case .acceptDevicePublicKey(let payload):
            DispatchQueue.main.async {
                errorMessage = nil
                if let onValidatedDevicePublicKey {
                    onValidatedDevicePublicKey(payload)
                } else {
                    onScan(code)
                }
            }
            return true
        }
    }

    // Routes validation errors either to the caller's custom UX or the default inline error text.
    private func reportValidationFailure(_ message: String) {
        if let onInvalidScan {
            onInvalidScan(message)
            return
        }
        errorMessage = message
    }
}

// UIViewRepresentable wrapper for AVCaptureSession camera preview.
// Handles camera setup and QR code metadata detection.
private struct CameraPreviewView: UIViewRepresentable {
    let onScan: (String) -> Bool
    
    // Builds a capture view that never opens a session in Canvas, so
    // scanner tiles can show overlay chrome without a live camera.
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(
            usesLiveCamera: QRCodeScannerView.shouldUseLiveCamera(
                environment: ProcessInfo.processInfo.environment
            )
        )
        view.onScan = onScan
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // No updates needed
    }
}

// UIView subclass that manages AVCaptureSession for QR scanning.
private class CameraPreviewUIView: UIView {
    var onScan: ((String) -> Bool)?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var hasCommittedScan = false
    private var lastRejectedCode: String?
    private var lastRejectedAt = Date.distantPast
    private let invalidScanCooldown: TimeInterval = 0.8
    private let metadataQueue = DispatchQueue(label: "iosapp.qr.metadata")
    private let sessionQueue = DispatchQueue(label: "iosapp.qr.session", qos: .userInitiated)
    
    // Skips AVCaptureSession construction in Canvas, where no capture
    // device exists and session setup would take the preview down.
    init(frame: CGRect = .zero, usesLiveCamera: Bool = true) {
        super.init(frame: frame)
        if usesLiveCamera {
            setupCamera()
        }
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }
    
    // Keeps preview geometry and scan focus region aligned with the visible viewport.
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        updateRectOfInterest()
    }
    
    // Configures a low-latency capture session optimized for QR detection throughput.
    private func setupCamera() {
        let session = AVCaptureSession()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        guard let device = AVCaptureDevice.default(for: .video) else {
            logError("No video device available", context: "QRScanner")
            return
        }
        
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            logError("Failed to create device input", context: "QRScanner")
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: metadataQueue)
            output.metadataObjectTypes = [.qr]
            metadataOutput = output
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)
        
        self.captureSession = session
        self.previewLayer = previewLayer
        
        sessionQueue.async {
            session.startRunning()
        }
    }
    
    // Ensures camera resources are released when scanner view is deallocated.
    deinit {
        sessionQueue.async { [captureSession] in
            captureSession?.stopRunning()
        }
    }

    // Narrows scanning to the centered overlay area to reduce unnecessary frame analysis.
    private func updateRectOfInterest() {
        guard let previewLayer, let metadataOutput else {
            return
        }
        let side = min(bounds.width, bounds.height) * 0.7
        let scanRect = CGRect(
            x: (bounds.width - side) / 2.0,
            y: (bounds.height - side) / 2.0,
            width: side,
            height: side
        )
        let normalizedRect = previewLayer.metadataOutputRectConverted(fromLayerRect: scanRect)
        let invalidRect = normalizedRect.isNull ||
            normalizedRect.isInfinite ||
            normalizedRect.width <= 0.01 ||
            normalizedRect.height <= 0.01

        if invalidRect {
            metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        metadataOutput.rectOfInterest = normalizedRect
    }

    // Suppresses repeated invalid detections so users are not flooded while framing the same QR.
    private func shouldCooldownInvalidScan(_ code: String) -> Bool {
        guard code == lastRejectedCode else {
            return false
        }
        return Date().timeIntervalSince(lastRejectedAt) < invalidScanCooldown
    }
}

extension CameraPreviewUIView: AVCaptureMetadataOutputObjectsDelegate {
    // Decides whether to continue scanning or commit based on validation outcome.
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasCommittedScan,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }

        if shouldCooldownInvalidScan(stringValue) {
            return
        }

        let didAccept = onScan?(stringValue) ?? false
        guard didAccept else {
            lastRejectedCode = stringValue
            lastRejectedAt = Date()
            return
        }

        hasCommittedScan = true
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
        sessionQueue.async { [captureSession] in
            captureSession?.stopRunning()
        }

        log("Detected QR code", context: "QRScanner")
    }
}

#Preview("Scanning") {
    NavigationStack {
        QRCodeScannerView(previewState: .scanning)
    }
}

#Preview("Permission Denied") {
    NavigationStack {
        QRCodeScannerView(previewState: .permissionDenied)
    }
}

#Preview("Scan Error") {
    NavigationStack {
        QRCodeScannerView(previewState: .scanError("Invalid QR code format"))
    }
}

