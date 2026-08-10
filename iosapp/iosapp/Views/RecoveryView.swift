import SwiftUI
import UIKit

// Runs the end-user recovery flow from a scanned/pasted bundle and returns to normal app identity afterwards.
struct RecoveryView: View {
    static let revokeCtaLabel = "Revoke used key"
    static let continueCtaLabel = "Continue"
    static let revokeDoneMessage = "Used key revoked. Create a new recovery key in Settings."

    enum RecoveryStep {
        case start
        case bundle
        case password
        case processing
        case serverUnreachable
        case blocked
        case done
        case error

        var title: String {
            switch self {
            case .start, .bundle, .password: return "Recover Access"
            case .processing: return "Recovering"
            case .serverUnreachable: return "Server Unreachable"
            case .blocked: return "Recovery Blocked"
            case .done: return "Recovery Complete"
            case .error: return "Error"
            }
        }
    }

    let initialInput: String?
    let onCompleted: () -> Void

    @State private var currentStep: RecoveryStep = .start
    @State private var input = ""
    @State private var password = ""
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var manualDiscoveryURL = ""
    @State private var isBusy = false
    @State private var showScanner = false
    @State private var completedRecovery: RecoveryKeyManager.RecoveryResult?
    @State private var didRevokeUsedKey = false

    private let manager = RecoveryKeyManager()

    // Supports deterministic previews for each wizard state without invoking recovery side effects.
    init(initialInput: String?, onCompleted: @escaping () -> Void, previewStep: RecoveryStep? = nil) {
        self.initialInput = initialInput
        self.onCompleted = onCompleted
        if let previewStep {
            _currentStep = State(initialValue: previewStep)
        }
    }

    var body: some View {
        Group {
            switch currentStep {
            case .start:
                startStepView
            case .bundle:
                bundleStepView
            case .password:
                passwordStepView
            case .processing:
                PairingProgressView(
                    isProcessing: true,
                    message: progressMessage ?? "Recovering..."
                )
            case .serverUnreachable:
                serverUnreachableStepView
            case .blocked:
                blockedStepView
            case .done:
                doneStepView
            case .error:
                PairingErrorView(
                    title: "Recovery Failed",
                    message: errorMessage,
                    onRetry: { currentStep = Self.initialStep(for: initialInput) },
                    onCancel: onCompleted
                )
            }
        }
        .navigationTitle(currentStep.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            currentStep = Self.initialStep(for: initialInput)
            if let initialInput {
                input = initialInput
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRCodeScannerView(
                    onScan: { scanned in
                        input = scanned
                        showScanner = false
                        currentStep = .password
                    },
                    onCancel: { showScanner = false },
                    validationMode: .recoveryBundle
                )
            }
        }
    }

    // Starts with two simple options so users quickly pick scan vs paste without extra form fields.
    private var startStepView: some View {
        VStack(spacing: 24) {
            Spacer()

            PairingStepIndicator(step: 1, phase: .sendKey)

            Image(systemName: "key.viewfinder")
                .font(.system(size: 68))
                .foregroundStyle(Color.brandGradient)

            Text("Recover with your backup")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Use your saved recovery QR or backup text.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button("Scan recovery QR") {
                    showScanner = true
                }
                .buttonStyle(PairingPrimaryButtonStyle())

                Button("Paste backup text") {
                    currentStep = .bundle
                }
                .buttonStyle(PairingSecondaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
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
                .padding(8)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        input = pasted
                    }
                }
                .font(.caption)

                Button("Scan instead") {
                    showScanner = true
                }
                .font(.caption)
            }
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

                Button("Back") {
                    currentStep = .start
                }
                .buttonStyle(PairingTertiaryButtonStyle())
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

                Button("Back") {
                    currentStep = initialInput == nil ? .bundle : .start
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
                .padding()
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

            PairingStepIndicator(step: 4, phase: .shareConfig)

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                Text("Recovery complete")
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .foregroundStyle(Color.brandGreen)

            Text("For best security, revoke the recovery key you just used.")
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
                    Button(Self.revokeCtaLabel) {
                        Task { await revokeUsedRecoveryKey() }
                    }
                    .buttonStyle(PairingPrimaryButtonStyle())

                    Button("Not now") {
                        onCompleted()
                    }
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
        return .start
    }

    // Keeps bundle parsing step-button enablement simple and testable.
    static func canAdvanceFromBundle(input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Encodes bundle validation routing so tests can assert password vs error transitions.
    static func nextStepAfterBundleValidation(input: String) -> RecoveryStep {
        guard canAdvanceFromBundle(input: input) else {
            return .bundle
        }
        return (try? RecoveryBundle.parseEnvelope(from: input)) != nil ? .password : .error
    }

    // Executes recover path and exposes manual discovery fallback when the original endpoint is unreachable.
    private func runRecovery() async {
        errorMessage = nil
        isBusy = true
        currentStep = .processing
        defer { isBusy = false }

        do {
            let result = try await manager.recover(
                input: input,
                password: password,
                discoveryURLOverride: manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualDiscoveryURL
            ) { message in
                Task { @MainActor in
                    progressMessage = message
                }
            }
            completedRecovery = result
            didRevokeUsedKey = false
            currentStep = .done
        } catch ConfigurationError.discoveryFetchFailed {
            errorMessage = "Discovery endpoint unreachable. Enter a new discovery URL and retry."
            if manualDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualDiscoveryURL = "http://replycant.local:8080"
            }
            currentStep = .serverUnreachable
        } catch RecoveryKeyManager.Error.alreadyConfiguredDevice {
            currentStep = .blocked
        } catch {
            errorMessage = error.localizedDescription
            currentStep = .error
        }
    }

    // Revokes used recovery material so one-time credentials cannot be reused after account recovery.
    private func revokeUsedRecoveryKey() async {
        guard let completedRecovery else {
            onCompleted()
            return
        }
        do {
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            try await manager.deleteRecoveryKey(uuid: completedRecovery.usedRecoveryUUID, repository: repository, gitDB: gitDB)
            didRevokeUsedKey = true
        } catch {
            errorMessage = error.localizedDescription
            currentStep = .error
        }
    }
}

#Preview("Recovery Start") {
    NavigationStack {
        RecoveryView(initialInput: nil, onCompleted: {}, previewStep: .start)
    }
}

#Preview("Recovery Password") {
    NavigationStack {
        RecoveryView(initialInput: "replycant://recover?v=1&d=abc", onCompleted: {}, previewStep: .password)
    }
}
