import SwiftUI
import LibGit2

// Guides first-time users through secure library setup via QR code scanning.
// Supports creating a new library or connecting to an existing one,
// including recovery by scanning a recovery QR on the connect path.
struct OnboardingView: View {
    let onComplete: () -> Void
    static let connectToExistingStepOneInstruction = "On your other device, go to Settings → Link a New Device and scan this code"
    static let connectToExistingStepOneContinueLabel = "Next"
    static let connectToExistingStepOneWaitingLabel = "Waiting for your other device to scan..."
    static let connectToExistingRecoveryShortcutLabel = "I have a recovery key"
    static let connectToExistingPasteBackupLabel = "Paste backup text"
    static let connectToExistingStepTwoHint = "Your other device should now be showing a green-bordered QR code. You can also scan a recovery QR here."
    static let connectToExistingRecoveryScanHint = "Scan your saved recovery QR, or paste backup text."
    static let serverSetupGuideText = "Before you continue, set up a Replycant server and make sure it's reachable from this device. Follow the guide below, then return here to scan your server QR code."
    static let serverSetupGuideURL = URL(string: "https://github.com/mr-andreas/replycant#getting-started")!
    static let startingSetupMessage = "Starting setup..."
    static let joiningNetworkMessage = "Joining your library's network..."
    
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
    @State private var recoveryInput: String?
    @State private var connectScanIntent: ConnectScanIntent

    // The secret this device published in its QR, and the task waiting for a
    // record sealed under it.
    //
    // One secret per attempt: it is what an eavesdropper who photographed the
    // QR would have, so it must not outlive the screen that showed it. The task
    // is held so leaving the screen stops the poll rather than leaving it
    // reading a slot nobody will write to.
    @State private var pairingSecret: PairingRecord.Secret?
    @State private var pairingWait: Task<Void, Never>?

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
        _recoveryInput = State(initialValue: nil)
        _connectScanIntent = State(initialValue: .pairing)
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
        _recoveryInput = State(initialValue: nil)
        _connectScanIntent = State(initialValue: .pairing)
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
                        initialInput: recoveryInput,
                        onCompleted: onComplete,
                        onCancel: { currentStep = .showPublicKey },
                        onScanAgain: { currentStep = .scanConfig }
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
                        title: ""
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

                Button(action: startPairingScan) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        Text(Self.connectToExistingStepOneContinueLabel)
                    }
                }
                .buttonStyle(PairingPrimaryButtonStyle(disabled: devicePublicKeyQR == nil))
                .disabled(devicePublicKeyQR == nil)
                .padding(.horizontal)

                Button(action: startRecoveryScan) {
                    Text(Self.connectToExistingRecoveryShortcutLabel)
                }
                .buttonStyle(PairingTertiaryButtonStyle())
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }

    // Wraps the scanner so it can accept either the other device's
    // server-config QR or a recovery QR from the same camera step.
    private var scanConfigView: some View {
        QRCodeScannerView(
            onScan: handleConnectScanned,
            onCancel: { currentStep = .showPublicKey },
            validationMode: .connectOrRecovery
        )
        .safeAreaInset(edge: .top) {
            if connectScanIntent == .pairing {
                PairingStepIndicator(step: 2, of: 2, phase: .shareConfig)
                    .padding(.top, 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                PairingHintBox(
                    message: connectScanIntent == .recovery
                        ? Self.connectToExistingRecoveryScanHint
                        : Self.connectToExistingStepTwoHint,
                    phase: .shareConfig
                )
                Button(action: startRecoveryPaste) {
                    Text(Self.connectToExistingPasteBackupLabel)
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
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
        stopWaitingForTailnetAuthorization()
        isConnectToExistingFlow = false
        currentStep = .serverSetupGuide
    }

    // MARK: - QR Code Handling

    private func handleQRCodeScanned(_ jsonString: String) {
        currentStep = .processing
        isProcessing = true
        progress = 0
        progressMessage = Self.startingSetupMessage
        
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
    
    // Routes a connect-flow scan to pairing or recovery so one camera step
    // can restore access without a separate recovery entry point.
    private func handleConnectScanned(_ scanned: String) {
        switch QRScanValidation.connectPayloadKind(code: scanned) {
        case .serverConfig:
            handleConfigScanned(scanned)
        case .recoveryBundle:
            stopWaitingForTailnetAuthorization()
            recoveryInput = scanned
            currentStep = .recover
        case nil:
            errorMessage = "Unsupported QR code. Expected server configuration or a recovery key."
            currentStep = .error
        }
    }

    // Continues the existing-device pairing dance after this device's key QR
    // has been shown for the other device to scan.
    private func startPairingScan() {
        connectScanIntent = .pairing
        currentStep = .scanConfig
    }

    // Jumps from the device-key screen to the same scanner when the user
    // already has a recovery QR instead of another paired device.
    private func startRecoveryScan() {
        connectScanIntent = .recovery
        currentStep = .scanConfig
    }

    // Opens the paste path so recovery still works when the backup is
    // text rather than a QR code.
    private func startRecoveryPaste() {
        stopWaitingForTailnetAuthorization()
        recoveryInput = nil
        currentStep = .recover
    }

    // Handles the config QR scanned from Device A during "Connect to Existing" flow.
    private func handleConfigScanned(_ jsonString: String) {
        // The LAN path won the race, so the tailnet wait can no longer produce
        // anything useful and would otherwise reconfigure the app underneath
        // this flow if a record showed up late.
        stopWaitingForTailnetAuthorization()
        currentStep = .processing
        isProcessing = true
        progress = 0
        progressMessage = Self.startingSetupMessage
        
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
        recoveryInput = nil
        connectScanIntent = .pairing
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

                // A fresh secret every time the QR is generated, so a photo of
                // an abandoned attempt's code cannot be used against this one.
                let secret = PairingRecord.createSecret()
                let jsonString = try TailnetPairing.deviceQRPayload(
                    publicKeySSH: publicKey,
                    agePublicKey: agePublicKey,
                    deviceName: name,
                    deviceUUID: uuid,
                    pairingSecret: secret.encoded
                )

                await MainActor.run {
                    devicePublicKeyQR = jsonString
                    pairingSecret = secret
                    // A tailnet deployment answers by publishing a record, and
                    // a LAN one by showing a config QR to scan. Both paths are
                    // live from here, because this device cannot tell which
                    // kind of deployment scanned it.
                    startWaitingForTailnetAuthorization(secret: secret)
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
    
    // MARK: - Tailnet Pairing

    // Waits for the deployment to authorize this device, then adopts what it
    // sent.
    //
    // On a tailnet deployment this is the only way in: the device has no CA to
    // trust, no tailnet credential, and no route to gitd, so it cannot ask for
    // anything and instead waits to be handed a sealed record. A LAN
    // deployment never publishes one, which is why this runs alongside the
    // config scan rather than replacing it - whichever answer arrives first is
    // the one that completes setup.
    //
    // A failure is left silent unless it happened after the record arrived. A
    // timeout here is the expected outcome on the LAN path, and surfacing it
    // would put an error on screen for users who paired successfully.
    private func startWaitingForTailnetAuthorization(secret: PairingRecord.Secret) {
        pairingWait?.cancel()
        pairingWait = Task {
            do {
                let ageIdentity = try ClientIdentityManager.shared.agePrivateKey()
                let payload = try await TailnetPairing.awaitAuthorization(
                    secretEncoded: secret.encoded,
                    slot: secret.slot,
                    ageIdentity: ageIdentity
                )
                if Task.isCancelled { return }

                await MainActor.run {
                    currentStep = .processing
                    isProcessing = true
                    progress = 0
                    progressMessage = Self.startingSetupMessage
                }
                try await performTailnetConnect(payload: payload)

                await MainActor.run {
                    isProcessing = false
                    progressMessage = "Setup complete!"
                    progress = 100
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { onComplete() }
            } catch is CancellationError {
                // Expected: the user moved on, or a config scan won the race.
            } catch let error as DiscoveryClient.DiscoveryError where error == .timedOut {
                log("No tailnet pairing record arrived; the LAN path is still available",
                    context: "Onboarding")
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    currentStep = .error
                }
            }
        }
    }

    // Stops the wait once it can no longer complete, so an abandoned attempt
    // does not keep polling a slot in the background.
    private func stopWaitingForTailnetAuthorization() {
        pairingWait?.cancel()
        pairingWait = nil
        pairingSecret = nil
    }

    // Joins the tailnet from an authorized record and clones over it.
    //
    // Mirrors performConnectToExisting, minus the local-network permission
    // prompt: a tailnet node dials through its own userspace stack, so the
    // device never touches the local network and iOS never asks.
    private func performTailnetConnect(payload: PairingRecord.Payload) async throws {
        log("=== PERFORMING TAILNET CONNECT (JOIN + CLONE) ===", context: "Onboarding")

        updateProgress(10, message: Self.joiningNetworkMessage)
        let serverURL = try await TailnetPairing.adopt(
            payload: payload,
            onProgress: { message in
                Task { @MainActor in
                    self.progressMessage = message
                }
            }
        )

        updateProgress(30, message: "Configuring secure transport...")
        guard let identity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw OnboardingError.repositoryError(
                "No identity found. The key should have been generated at first boot.")
        }
        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw OnboardingError.repositoryError("Failed to load CA certificate")
        }
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)

        updateProgress(40, message: "Cloning repository...")
        let repoPath = RepositoryManager.shared.repositoryPath()
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
        log("Tailnet connect completed successfully", context: "Onboarding")
    }

    // MARK: - Bootstrap Setup
    
    // Performs bootstrap setup and commits both identity keys and initial KEK epoch metadata in one atomic push.
    private func performBootstrapSetup(qrCodeJSON: String) async throws {
        log("=== PERFORMING BOOTSTRAP SETUP (CREATE + PUSH) ===", context: "Onboarding")
        // Step 1: Parse and store server configuration
        updateProgress(10, message: "Configuring server...")
        try await adoptServerConfigQR(qrCodeJSON)
        
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
        
        try await gitDB.push()

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
        try await adoptServerConfigQR(configJSON)
        
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
    
    /// Installs the CA and, when the QR is a first-device tailnet join,
    /// brings the node up before any gitd request.
    ///
    /// Ordered this way because gitd's MagicDNS name does not resolve until
    /// the node is up, and the join itself needs the CA already pinned.
    private func adoptServerConfigQR(_ json: String) async throws {
        guard let payload = QRScanValidation.parseServerConfig(json) else {
            throw OnboardingError.repositoryError(
                "Invalid QR code. Expected server configuration.")
        }
        switch payload {
        case .lan(let ca, let url):
            try ServerConfigurationManager.shared.configure(url: url, caCertificate: ca)
            updateProgress(20, message: "Requesting local network access...")
            guard let configuration = ServerConfigurationManager.shared.loadConfiguration() else {
                throw OnboardingError.repositoryError("Server configuration missing after QR scan")
            }
            try await LocalNetworkPermissionManager.shared.requestPermissionIfNeeded(
                gitServerURL: configuration.url,
                lfsServerURL: ServerConfigurationManager.shared.loadLFSURL()
            )
        case .tailnet(let ca, let headscaleURL, let preauthKey):
            try ServerConfigurationManager.shared.configure(
                url: TailnetConfiguration.gitdURL,
                caCertificate: ca
            )
            updateProgress(20, message: Self.joiningNetworkMessage)
            try await TailnetBootstrap.shared.joinAndPersist(
                headscaleURL: headscaleURL,
                preauthKey: preauthKey,
                onProgress: { message in
                    Task { @MainActor in
                        self.progressMessage = message
                    }
                }
            )
        }
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
// Distinguishes pairing vs recovery on the shared connect scanner so
// step chrome and hint copy match why the user opened the camera.
enum ConnectScanIntent {
    case pairing
    case recovery
}

// Names each first-launch screen so routing and titles stay explicit.
// CaseIterable lets the screen gallery fail a test when a new step is
// added without a corresponding canvas tile.
enum OnboardingStep: CaseIterable {
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
