import SwiftUI
import LibGit2

// Guides first-time users through secure library setup via QR code scanning.
// Supports creating a new library or connecting to an existing one.
struct OnboardingView: View {
    let onComplete: () -> Void
    static let connectToExistingStepOneInstruction = "On your other device, go to Settings → Link a New Device and scan this code"
    static let connectToExistingStepOneContinueLabel = "Next"
    static let connectToExistingStepOneWaitingLabel = "Waiting for your other device to scan..."
    static let connectToExistingStepTwoHint = "Your other device should now be showing a green-bordered QR code"
    static let serverSetupGuideText = "Before you continue, set up a Replycant server and make sure it's reachable from this device. Follow the guide below, then return here to scan your server QR code."
    static let serverSetupGuideURL = URL(string: "https://github.com/mr-andreas/replycant#getting-started")!
    
    @State private var currentStep: OnboardingStep
    @State private var introPageIndex: Int
    @State private var isProcessing: Bool
    @State private var errorMessage: String?
    @State private var progressMessage: String
    @State private var progress: Double
    @State private var devicePublicKeyQR: String?
    @State private var deviceName: String
    @State private var deviceUUID: String
    @State private var isConnectToExistingFlow: Bool

    // Initializes the onboarding router so first-launch users see product context before setup actions.
    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _currentStep = State(initialValue: .intro)
        _introPageIndex = State(initialValue: 0)
        _isProcessing = State(initialValue: false)
        _progressMessage = State(initialValue: "")
        _progress = State(initialValue: 0)
        _deviceName = State(initialValue: "")
        _deviceUUID = State(initialValue: "")
        _isConnectToExistingFlow = State(initialValue: false)
    }

    /// Preview-only initializer that parks the view at a specific step
    /// with sample data, avoiding any singleton access.
    // Enables deterministic previews for any onboarding step without hitting runtime-only dependencies.
    init(
        preview step: OnboardingStep,
        isProcessing: Bool = false,
        progressMessage: String = "",
        progress: Double = 0,
        errorMessage: String? = nil,
        devicePublicKeyQR: String? = nil,
        deviceName: String = "preview-device"
    ) {
        self.onComplete = {}
        _currentStep = State(initialValue: step)
        _introPageIndex = State(initialValue: 0)
        _isProcessing = State(initialValue: isProcessing)
        _progressMessage = State(initialValue: progressMessage)
        _progress = State(initialValue: progress)
        _errorMessage = State(initialValue: errorMessage)
        _devicePublicKeyQR = State(initialValue: devicePublicKeyQR)
        _deviceName = State(initialValue: deviceName)
        _deviceUUID = State(initialValue: "preview-uuid")
        _isConnectToExistingFlow = State(initialValue: step == .showPublicKey || step == .scanConfig)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                switch currentStep {
                case .intro:
                    introView
                case .welcome:
                    welcomeView
                case .serverSetupGuide:
                    serverSetupGuideView
                case .scanQR:
                    QRCodeScannerView(
                        onScan: handleQRCodeScanned,
                        onCancel: { currentStep = .welcome },
                        validationMode: .serverConfig
                    )
                case .showPublicKey:
                    showPublicKeyView
                case .scanConfig:
                    scanConfigView
                case .processing:
                    processingView
                case .error:
                    errorView
                case .recover:
                    RecoveryView(
                        initialInput: nil,
                        onCompleted: onComplete,
                        onCancel: { currentStep = .welcome }
                    )
                }
            }
            .navigationTitle(currentStep.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if currentStep == .intro {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") {
                            currentStep = .welcome
                        }
                    }
                }
            }
        }
    }
    
    // Explains core app benefits before users choose create/connect onboarding paths.
    private var introView: some View {
        VStack(spacing: 20) {
            TabView(selection: $introPageIndex) {
                ForEach(Array(OnboardingIntroPage.defaultPages.enumerated()), id: \.offset) { offset, page in
                    VStack(spacing: 20) {
                        Spacer()

                        if let logoName = page.logoName {
                            Image(logoName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        } else if let iconName = page.iconName {
                            Image(systemName: iconName)
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(Color.brandGradient)
                        }

                        Text(page.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Text(page.body)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)

                        Spacer()
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            Button(action: advanceIntroPage) {
                Text(introPageIndex == OnboardingIntroPage.defaultPages.count - 1 ? "Get Started" : "Next")
            }
            .buttonStyle(PairingPrimaryButtonStyle())
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Welcome View
    
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image("ReplycantLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            
            Text("Replycant")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Welcome to Replycant, the secure photo library")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 16) {
                Button(action: startCreateLibrary) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Create a new library")
                    }
                }
                .buttonStyle(PairingPrimaryButtonStyle())
                
                Button(action: { startConnectToExisting() }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Connect to an existing library")
                    }
                }
                .buttonStyle(PairingSecondaryButtonStyle())

                Button(action: { currentStep = .recover }) {
                    HStack {
                        Image(systemName: "key.viewfinder")
                        Text("Recover with a recovery key")
                    }
                }
                .buttonStyle(PairingSecondaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Surfaces a concrete server setup guide before QR scanning so users can
    // complete infrastructure prerequisites without leaving onboarding guessing.
    private var serverSetupGuideView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 56))
                .foregroundStyle(Color.brandGradient)

            Text("Set up a Replycant server")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(Self.serverSetupGuideText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Link(destination: Self.serverSetupGuideURL) {
                Label("Open server setup guide", systemImage: "arrow.up.right.square")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PairingSecondaryButtonStyle())
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 16) {
                Button(action: { currentStep = .scanQR }) {
                    Text("Continue")
                }
                .buttonStyle(PairingPrimaryButtonStyle())

                Button(action: { currentStep = .welcome }) {
                    Text("Go Back")
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
    
    // MARK: - Processing View
    
    private var processingView: some View {
        PairingProgressView(
            isProcessing: isProcessing,
            message: progressMessage,
            progress: progress
        )
    }
    
    // MARK: - Error View
    
    private var errorView: some View {
        PairingErrorView(
            message: errorMessage,
            onRetry: {
                if isConnectToExistingFlow {
                    currentStep = .showPublicKey
                } else {
                    currentStep = .scanQR
                }
            },
            onCancel: {
                currentStep = .welcome
                isConnectToExistingFlow = false
            }
        )
    }
    
    // MARK: - Show Public Key View
    
    private var showPublicKeyView: some View {
        ScrollView {
            VStack(spacing: 16) {
                PairingStepIndicator(step: 1, of: 2, phase: .sendKey)
                    .padding(.top, 16)

                Text("Show this to your other device")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(Self.connectToExistingStepOneInstruction)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let qrData = devicePublicKeyQR {
                    QRCodeDisplayView(
                        data: qrData,
                        title: deviceName,
                        subtitle: "Device Public Key"
                    )
                } else {
                    ProgressView("Generating key...")
                }

                HStack(spacing: 10) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(Self.connectToExistingStepOneWaitingLabel)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal)

                Button(action: { currentStep = .scanConfig }) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        Text(Self.connectToExistingStepOneContinueLabel)
                    }
                }
                .buttonStyle(PairingPrimaryButtonStyle(disabled: devicePublicKeyQR == nil))
                .disabled(devicePublicKeyQR == nil)
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }

    // Wraps the scanner with explicit Step 2 cues so users can confirm they
    // are scanning the correct follow-up QR from the other device.
    private var scanConfigView: some View {
        QRCodeScannerView(
            onScan: handleConfigScanned,
            onCancel: { currentStep = .showPublicKey },
            validationMode: .serverConfig
        )
        .safeAreaInset(edge: .top) {
            PairingStepIndicator(step: 2, of: 2, phase: .shareConfig)
                .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            PairingHintBox(message: Self.connectToExistingStepTwoHint, phase: .shareConfig)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }
    
    // Advances intro pagination, then hands off to the existing onboarding actions screen.
    private func advanceIntroPage() {
        if introPageIndex < OnboardingIntroPage.defaultPages.count - 1 {
            introPageIndex += 1
            return
        }
        currentStep = .welcome
    }

    // Starts create-library onboarding at server setup guidance so users can bootstrap immediately.
    private func startCreateLibrary() {
        isConnectToExistingFlow = false
        currentStep = .serverSetupGuide
    }

    // MARK: - QR Code Handling

    private func handleQRCodeScanned(_ jsonString: String) {
        currentStep = .processing
        isProcessing = true
        progress = 0
        
        Task {
            do {
                try await performBootstrapSetup(qrCodeJSON: jsonString)
                
                await MainActor.run {
                    isProcessing = false
                    progressMessage = "Setup complete!"
                    progress = 100
                }
                
                // Brief delay to show completion
                try await Task.sleep(nanoseconds: 1_000_000_000)
                
                await MainActor.run {
                    onComplete()
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
    
    // Handles the config QR scanned from Device A during "Connect to Existing" flow.
    private func handleConfigScanned(_ jsonString: String) {
        currentStep = .processing
        isProcessing = true
        progress = 0
        
        Task {
            do {
                try await performConnectToExisting(configJSON: jsonString)
                
                await MainActor.run {
                    isProcessing = false
                    progressMessage = "Setup complete!"
                    progress = 100
                }
                
                // Brief delay to show completion
                try await Task.sleep(nanoseconds: 1_000_000_000)
                
                await MainActor.run {
                    onComplete()
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
    
    // Initiates connect-to-existing with both mTLS and age public keys so Device A can grant encryption access.
    private func startConnectToExisting() {
        log("=== STARTING CONNECT TO EXISTING FLOW ===", context: "Onboarding")
        isConnectToExistingFlow = true
        currentStep = .showPublicKey
        
        Task {
            do {
                // Generate device name and UUID
                let name = getDeviceName()
                let uuid = UUID().uuidString.lowercased()
                
                await MainActor.run {
                    deviceName = name
                    deviceUUID = uuid
                }
                
                log("Retrieving device identity for: \(name) (\(uuid))", context: "Onboarding")
                // The device identity was already generated at first boot.
                // We only retrieve the public key to show in the QR code.
                
                // Get the public key
                let publicKey = try ClientIdentityManager.shared.sshPublicKey(comment: name)
                
                // Build QR code JSON.
                let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
                let json: [String: String] = [
                    "pubkey": publicKey,
                    "age_pubkey": agePublicKey,
                    "name": name,
                    "uuid": uuid
                ]
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    throw OnboardingError.repositoryError("Failed to create QR code")
                }
                
                await MainActor.run {
                    devicePublicKeyQR = jsonString
                }
                
                log("Generated device key QR for \(name) (\(uuid))", context: "Onboarding")
                
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    currentStep = .error
                }
            }
        }
    }
    
    // MARK: - Bootstrap Setup
    
    // Performs bootstrap setup and commits both identity keys and initial KEK epoch metadata in one atomic push.
    private func performBootstrapSetup(qrCodeJSON: String) async throws {
        log("=== PERFORMING BOOTSTRAP SETUP (CREATE + PUSH) ===", context: "Onboarding")
        // Step 1: Parse and store server configuration
        updateProgress(10, message: "Configuring server...")
        try ServerConfigurationManager.shared.configure(fromQRCodeString: qrCodeJSON)

        // Step 2: Trigger local-network permission before the first push.
        updateProgress(20, message: "Requesting local network access...")
        guard let configuration = ServerConfigurationManager.shared.loadConfiguration() else {
            throw OnboardingError.repositoryError("Server configuration missing after QR scan")
        }
        try await LocalNetworkPermissionManager.shared.requestPermissionIfNeeded(
            gitServerURL: configuration.url,
            lfsServerURL: ServerConfigurationManager.shared.loadLFSURL()
        )
        
        // Step 3: Configure mTLS transport for libgit2 push/pull
        updateProgress(30, message: "Configuring secure transport...")
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw OnboardingError.repositoryError("Failed to load mTLS credentials")
        }
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
        
        // Step 4: Create local repository
        updateProgress(45, message: "Creating repository...")
        let repoPath = RepositoryManager.shared.repositoryPath()
        
        // Remove existing repo if present (for fresh setup)
        if FileManager.default.fileExists(atPath: repoPath) {
            log("Removing existing directory at \(repoPath) before creating new repo", context: "Onboarding")
            try FileManager.default.removeItem(atPath: repoPath)
        }
        
        let repository = try Repository.create(at: repoPath)
        
        // Step 5: Build key files and encryption bootstrap files.
        updateProgress(55, message: "Preparing public key...")
        let deviceName = getDeviceName()
        let publicKey = try ClientIdentityManager.shared.sshPublicKey(comment: deviceName)
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let pubkeyPath = "pubkeys/\(deviceName).pub"
        let agePath = "pubkeys/\(deviceName).age"
        let kekBootstrapFiles = try KEKEpochManager(repository: repository).bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        
        // Step 6: Create initial commit.
        updateProgress(70, message: "Creating initial commit...")
        var initialFiles: [(path: String, content: String)] = [
            (path: pubkeyPath, content: publicKey),
            (path: agePath, content: agePublicKey)
        ]
        initialFiles.append(contentsOf: kekBootstrapFiles)
        let gitDB = try GitDBManager.shared.getGitDB()
        try await gitDB.commitFiles(
            message: "Initial commit: add device key for \(deviceName)",
            files: initialFiles
        )
        
        // Step 7: Add remote with mtls+https:// scheme and push using libgit2
        updateProgress(85, message: "Connecting to server...")
        
        guard let serverURL = ServerConfigurationManager.shared.loadURL() else {
            throw OnboardingError.noServerURL
        }
        
        // Convert to mtls+https:// scheme so libgit2 routes through our custom transport
        let mtlsURL = MTLSTransport.convertToMTLSScheme(serverURL)
        try repository.addRemote(name: "origin", url: mtlsURL)
        
        updateProgress(90, message: "Pushing to server...")
        
        // Push using libgit2's native push (handles pack building and protocol correctly)
        try repository.push(remoteName: "origin", branchName: "main")

        updateProgress(92, message: "Building media index...")
        try await gitDB.syncToHead { phase, loaded, total in
            let fraction = total > 0 ? Double(loaded) / Double(total) : 0
            Task { @MainActor in
                self.progress = 92 + (fraction * 7)
                self.progressMessage = "\(phase) (\(loaded)/\(total))"
            }
        }
        
        updateProgress(100, message: "Setup complete!")
        log("Bootstrap setup completed successfully", context: "Onboarding")
    }
    
    @MainActor
    private func updateProgress(_ value: Double, message: String) {
        progress = value
        progressMessage = message
    }
    
    // MARK: - Connect to Existing Setup
    
    // Performs the connect-to-existing flow: configure server, configure mTLS, clone repo.
    // The device identity was already generated at first boot.
    // We use that identity for authentication since its public key was added by Device A.
    private func performConnectToExisting(configJSON: String) async throws {
        log("=== PERFORMING CONNECT TO EXISTING (CLONE) ===", context: "Onboarding")
        // Step 1: Parse and store server configuration
        updateProgress(10, message: "Configuring server...")
        try ServerConfigurationManager.shared.configure(fromQRCodeString: configJSON)

        // Step 2: Trigger local-network permission before the first clone.
        updateProgress(20, message: "Requesting local network access...")
        guard let configuration = ServerConfigurationManager.shared.loadConfiguration() else {
            throw OnboardingError.repositoryError("Server configuration missing after QR scan")
        }
        try await LocalNetworkPermissionManager.shared.requestPermissionIfNeeded(
            gitServerURL: configuration.url,
            lfsServerURL: ServerConfigurationManager.shared.loadLFSURL()
        )
        
        // Step 3: Verify we have the identity that was generated at first boot
        // This is critical - we must use the same key whose public part was shared via QR
        guard let identity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw OnboardingError.repositoryError("No identity found. The key should have been generated at first boot.")
        }
        
        // Step 4: Configure mTLS transport for libgit2 clone
        updateProgress(30, message: "Configuring secure transport...")
        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw OnboardingError.repositoryError("Failed to load CA certificate")
        }
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
        
        // Step 5: Clone repository and hydrate local index.
        let repoPath = RepositoryManager.shared.repositoryPath()

        // Step 6: Clone repository (run on background to avoid blocking UI).
        updateProgress(40, message: "Cloning repository...")
        guard let serverURL = ServerConfigurationManager.shared.loadURL() else {
            throw OnboardingError.noServerURL
        }

        log("Cloning from \(serverURL) to \(repoPath)", context: "Onboarding")
        try await RepositoryBootstrap.clone(
            serverURL: serverURL,
            repositoryPath: repoPath
        ) { message, phaseProgress in
            Task { @MainActor in
                self.progress = RepositoryBootstrap.scaled(phaseProgress, into: 40...80)
                self.progressMessage = message
            }
        }

        updateProgress(80, message: "Building media index...")
        try await RepositoryBootstrap.hydrateIndex(
            resetDatabase: false
        ) { message, phaseProgress in
            Task { @MainActor in
                self.progress = RepositoryBootstrap.scaled(phaseProgress, into: 80...99)
                self.progressMessage = message
            }
        }
        
        updateProgress(100, message: "Setup complete!")
        log("Connect to existing setup completed successfully", context: "Onboarding")
    }
    
    @MainActor
    private func getDeviceName() -> String {
        // Use device name or generate a unique identifier
        let deviceName = UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
        return deviceName
    }
}

// MARK: - Supporting Types

// Represents the onboarding router states used to control secure setup progression.
enum OnboardingStep {
    case intro
    case welcome
    case serverSetupGuide
    case scanQR
    case showPublicKey
    case scanConfig
    case processing
    case error
    case recover
    
    // Supplies concise navigation titles for each onboarding step screen.
    var title: String {
        switch self {
        case .intro: return "Welcome"
        case .welcome: return ""
        case .serverSetupGuide: return "Server Setup"
        case .scanQR: return "Scan QR Code"
        case .showPublicKey: return "Your Device Key"
        case .scanConfig: return "Scan Configuration"
        case .processing: return "Setting Up"
        case .error: return "Error"
        case .recover: return "Recover Access"
        }
    }
}

// Defines static onboarding intro page content so copy and icon order stay testable.
struct OnboardingIntroPage {
    let iconName: String?
    let logoName: String?
    let title: String
    let body: String

    static let defaultPages: [OnboardingIntroPage] = [
        OnboardingIntroPage(
            iconName: nil,
            logoName: "ReplycantLogo",
            title: "Welcome to Replycant",
            body: "An open-source photo library built for privacy, durability, and independence. No secret agenda, no hidden algorithms, no lock-in."
        ),
        OnboardingIntroPage(
            iconName: "lock.shield",
            logoName: nil,
            title: "Your data stays yours",
            body: "Privacy is a core design goal. Your data is encrypted at rest, and the keys that protect it never leave your device."
        ),
        OnboardingIntroPage(
            iconName: "arrow.triangle.branch",
            logoName: nil,
            title: "Durable and portable",
            body: "Under the hood, Replycant uses git - the same proven technology developers rely on to preserve history and synchronize work across devices. Your library is designed for reliable replication, not platform lock-in."
        )
    ]
}

private enum OnboardingError: Error, LocalizedError {
    case noServerURL
    case repositoryError(String)
    
    var errorDescription: String? {
        switch self {
        case .noServerURL:
            return "Server URL not configured"
        case .repositoryError(let message):
            return "Repository error: \(message)"
        }
    }
}

#Preview("Intro") {
    OnboardingView(onComplete: {})
}

#Preview("Welcome") {
    OnboardingView(preview: .welcome)
}

#Preview("Server Setup Guide") {
    OnboardingView(preview: .serverSetupGuide)
}

#Preview("Show Public Key") {
    OnboardingView(
        preview: .showPublicKey,
        devicePublicKeyQR: "{\"pubkey\":\"ssh-ed25519 AAAA...\",\"age_pubkey\":\"age1...\",\"name\":\"preview-iphone\",\"uuid\":\"abc123\"}",
        deviceName: "preview-iphone"
    )
}

#Preview("Processing") {
    OnboardingView(
        preview: .processing,
        isProcessing: true,
        progressMessage: "Cloning repository...",
        progress: 42
    )
}

#Preview("Error") {
    OnboardingView(
        preview: .error,
        errorMessage: "Server URL not configured"
    )
}
