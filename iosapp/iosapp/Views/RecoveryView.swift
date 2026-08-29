import SwiftUI

// Runs the end-user recovery flow from a scanned/pasted bundle and returns to normal app identity afterwards.
struct RecoveryView: View {
    static let revokeCtaLabel = "Revoke used key"
    static let revokingCtaLabel = "Revoking used key..."
    static let continueCtaLabel = "Continue"
    // Explains why revoke is the safer next step and that a replacement
    // key can wait until the user is inside the recovered app.
    static let revokeGuidanceMessage =
        "For best security, revoke the recovery key you just used. You can create a new one after you get into the app."
    static let revokeDoneMessage = "Used key revoked. Create a new recovery key in Settings."
    static let cancelCtaLabel = "Cancel"
    // Tells the user a typo or wrong secret is why unlock failed,
    // instead of a Recovery Failed screen with a CryptoKit code.
    static let wrongPasswordMessage = "The recovery password is incorrect."
    // Discovery already pinned this server's CA, so a 401 means the key
    // used to be registered here and has since been deleted.
    static let keyRejectedMessage = "The server rejected this recovery key. It matches this server's certificate, so it was registered here before and has since been deleted. Use a different recovery key, or pair from a device that still has access."

    // Names each recovery-wizard screen so routing and titles stay explicit.
    // CaseIterable lets the screen gallery fail a test when a new step is
    // added without a corresponding canvas tile.
    enum RecoveryStep: CaseIterable {
        case bundle
        case password
        case processing
        case serverUnreachable
        case blocked
        case keyRejected
        case done
        case error

        // Keeps navigation titles aligned with the remaining
        // password, paste, and outcome screens.
        var title: String {
            switch self {
            case .bundle, .password: return "Recover Access"
            case .processing: return "Recovering"
            case .serverUnreachable: return "Server Unreachable"
            case .blocked: return "Recovery Blocked"
            case .keyRejected: return "Recovery Key Rejected"
            case .done: return "Recovery Complete"
            case .error: return "Error"
            }
        }
    }

    let initialInput: String?
    let onCompleted: () -> Void
    let onCancel: () -> Void
    let onScanAgain: () -> Void

    @State private var currentStep: RecoveryStep = .bundle
    @State private var input = ""
    @State private var password = ""
    @State private var progressMessage: String?
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var manualDiscoveryURL = ""
    @State private var isBusy = false
    @State private var completedRecovery: RecoveryKeyManager.RecoveryResult?
    @State private var didRevokeUsedKey = false
    @State private var isRevokingUsedKey = false

    private let manager = RecoveryKeyManager()
    // Keeps an injected Canvas step available after appear so outcome
    // screens are not overwritten by input-based initial routing.
    private let previewStep: RecoveryStep?

    // Supports deterministic previews for each wizard state without invoking recovery side effects.
    init(
        initialInput: String?,
        onCompleted: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onScanAgain: @escaping () -> Void = {},
        previewStep: RecoveryStep? = nil,
        previewIsRevoking: Bool = false
    ) {
        self.initialInput = initialInput
        self.onCompleted = onCompleted
        self.onCancel = onCancel
        self.onScanAgain = onScanAgain
        self.previewStep = previewStep
        if let previewStep {
            _currentStep = State(initialValue: previewStep)
        }
        _isRevokingUsedKey = State(initialValue: previewIsRevoking)
    }

    var body: some View {
        Group {
            switch currentStep {
            case .bundle:
                bundleStepView
            case .password:
                passwordStepView
            case .processing:
                PairingProgressView(
                    isProcessing: true,
                    message: progressMessage ?? "Recovering...",
                    progress: progress
                )
            case .serverUnreachable:
                serverUnreachableStepView
            case .blocked:
                blockedStepView
            case .keyRejected:
                PairingErrorView(
                    title: "Recovery Key Not Registered",
                    message: Self.keyRejectedMessage,
                    retryLabel: "Use a different key",
                    onRetry: onScanAgain,
                    onCancel: onCancel
                )
            case .done:
                doneStepView
            case .error:
                PairingErrorView(
                    title: "Recovery Failed",
                    message: errorMessage,
                    onRetry: onScanAgain,
                    onCancel: onCancel
                )
            }
        }
        .navigationTitle(currentStep.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if currentStep == .bundle {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .onAppear {
            currentStep = Self.resolvedInitialStep(
                previewStep: previewStep,
                initialInput: initialInput
            )
            if let initialInput {
                input = initialInput
            }
        }
    }

    // Keeps manual text entry isolated so parsing failures are clear and easy to correct.
    private var bundleStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 1, phase: .sendKey)

            Text("Paste recovery bundle")
                .font(.title2)
                .fontWeight(.semibold)

            TextEditor(text: $input)
                .frame(minHeight: 160)
                .pairingFieldBackground(padding: 8)
                .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("Next") {
                    let next = Self.nextStepAfterBundleValidation(input: input)
                    if next == .password {
                        errorMessage = nil
                        currentStep = .password
                    } else if next == .error {
                        errorMessage = "Invalid recovery bundle format."
                    }
                }
                .disabled(!Self.canAdvanceFromBundle(input: input))
                .buttonStyle(PairingPrimaryButtonStyle(disabled: !Self.canAdvanceFromBundle(input: input)))
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Separates password entry as its own step so users focus on unlock only after input is accepted.
    private var passwordStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 2, phase: .sendKey)

            Text("Enter recovery password")
                .font(.title2)
                .fontWeight(.semibold)

            PasswordEntryView(
                mode: .recover,
                password: $password
            )
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("Recover") {
                    Task { await runRecovery() }
                }
                .disabled(isBusy || password.isEmpty)
                .buttonStyle(PairingPrimaryButtonStyle(disabled: isBusy || password.isEmpty))

                Button(Self.cancelCtaLabel) {
                    onCancel()
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Keeps discovery retry focused on one action when the pinned server cannot be reached.
    private var serverUnreachableStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 3, phase: .sendKey)

            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Discovery server unreachable")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            TextField("http://server:8080", text: $manualDiscoveryURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .pairingFieldBackground()
                .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("Retry recovery") {
                    Task { await runRecovery() }
                }
                .disabled(manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(PairingPrimaryButtonStyle(disabled: manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                Button("Back") {
                    currentStep = .password
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Gives explicit guidance when recovery is attempted on a configured install.
    private var blockedStepView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Recovery blocked on configured devices")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Uninstall and reinstall the app, then run recovery before setting up any server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 12) {
                Button("Close") {
                    onCompleted()
                }
                .buttonStyle(PairingPrimaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Finishes with one explicit replace-or-continue decision after successful recovery.
    private var doneStepView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Recovery complete")
                .font(.title2)
                .fontWeight(.semibold)

            Text(Self.revokeGuidanceMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if let completedRecovery {
                Text("Used key: \(completedRecovery.usedRecoveryLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                if didRevokeUsedKey {
                    Text(Self.revokeDoneMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Button(Self.continueCtaLabel) {
                        onCompleted()
                    }
                    .buttonStyle(PairingPrimaryButtonStyle())
                } else {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    Button {
                        Task { await revokeUsedRecoveryKey() }
                    } label: {
                        HStack(spacing: 8) {
                            if isRevokingUsedKey {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(Self.revokeCtaTitle(isRevoking: isRevokingUsedKey))
                        }
                    }
                    .disabled(isRevokingUsedKey)
                    .buttonStyle(PairingPrimaryButtonStyle(disabled: isRevokingUsedKey))

                    Button("Not now") {
                        onCompleted()
                    }
                    .disabled(!Self.canDismissDoneStep(isRevoking: isRevokingUsedKey))
                    .buttonStyle(PairingTertiaryButtonStyle())
                }

            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Keeps initial routing deterministic for tests and deep-link behavior.
    static func initialStep(for initialInput: String?) -> RecoveryStep {
        if let initialInput, !initialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .password
        }
        return .bundle
    }

    // Keeps an injected preview step from being overwritten on appear, so
    // Canvas can park the wizard on outcome screens that no real input
    // can reach.
    static func resolvedInitialStep(
        previewStep: RecoveryStep?,
        initialInput: String?
    ) -> RecoveryStep {
        previewStep ?? initialStep(for: initialInput)
    }

    // Keeps bundle parsing step-button enablement simple and testable.
    static func canAdvanceFromBundle(input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Relabels the revoke CTA while the commit-and-push is in flight
    // so the same button shows that work is happening.
    static func revokeCtaTitle(isRevoking: Bool) -> String {
        isRevoking ? revokingCtaLabel : revokeCtaLabel
    }

    // Blocks leaving Recovery Complete mid-revoke so a push cannot be
    // abandoned by tapping Not now.
    static func canDismissDoneStep(isRevoking: Bool) -> Bool {
        !isRevoking
    }

    // Encodes bundle validation routing so tests can assert password vs error transitions.
    static func nextStepAfterBundleValidation(input: String) -> RecoveryStep {
        guard canAdvanceFromBundle(input: input) else {
            return .bundle
        }
        return (try? RecoveryBundle.parseEnvelope(from: input)) != nil ? .password : .error
    }

    // Executes recover path, keeps wrong passwords on the password
    // step, exposes discovery fallback when the endpoint is
    // unreachable, and treats a 401 as a deleted recovery key.
    private func runRecovery() async {
        errorMessage = nil
        isBusy = true
        currentStep = .processing
        progress = 0
        defer { isBusy = false }

        do {
            let result = try await manager.recover(
                input: input,
                password: password,
                discoveryURLOverride: manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualDiscoveryURL
            ) { message, phaseProgress in
                Task { @MainActor in
                    progressMessage = message
                    progress = phaseProgress
                }
            }
            completedRecovery = result
            didRevokeUsedKey = false
            currentStep = .done
        } catch RecoveryBundle.Error.wrongPassword {
            errorMessage = Self.wrongPasswordMessage
            currentStep = .password
        } catch ConfigurationError.discoveryFetchFailed {
            errorMessage = "Discovery endpoint unreachable. Enter a new discovery URL and retry."
            if manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualDiscoveryURL = "http://replycant.local:8080"
            }
            currentStep = .serverUnreachable
        } catch RecoveryKeyManager.Error.alreadyConfiguredDevice {
            currentStep = .blocked
        } catch RecoveryKeyManager.Error.recoveryKeyNotAuthorized {
            currentStep = .keyRejected
        } catch {
            errorMessage = error.localizedDescription
            currentStep = .error
        }
    }

    // Revokes used recovery material so one-time credentials cannot be reused after account recovery.
    private func revokeUsedRecoveryKey() async {
        guard !isRevokingUsedKey else { return }
        guard let completedRecovery else {
            onCompleted()
            return
        }
        errorMessage = nil
        isRevokingUsedKey = true
        defer { isRevokingUsedKey = false }
        do {
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            try await manager.deleteRecoveryKey(uuid: completedRecovery.usedRecoveryUUID, repository: repository, gitDB: gitDB)
            didRevokeUsedKey = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Recovery Bundle") {
    NavigationStack {
        RecoveryView(initialInput: nil, onCompleted: {}, onCancel: {}, previewStep: .bundle)
    }
}

#Preview("Recovery Password") {
    NavigationStack {
        RecoveryView(initialInput: "replycant://recover?v=1&d=abc", onCompleted: {}, onCancel: {}, previewStep: .password)
    }
}
