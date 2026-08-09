import SwiftUI
import UIKit

// Runs the end-user recovery flow from a scanned/pasted bundle and returns to normal app identity afterwards.
struct RecoveryView: View {
    let initialInput: String?
    let onCompleted: () -> Void

    @State private var input = ""
    @State private var label = ""
    @State private var password = ""
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var manualDiscoveryURL = ""
    @State private var isBusy = false
    @State private var showScanner = false
    @State private var showReplacePrompt = false
    @State private var completedRecovery: RecoveryKeyManager.RecoveryResult?

    private let manager = RecoveryKeyManager()

    var body: some View {
        List {
            Section("Recovery Bundle") {
                TextEditor(text: $input)
                    .frame(minHeight: 120)
                HStack {
                    Button("Scan QR") { showScanner = true }
                    Button("Paste") {
                        if let pasted = UIPasteboard.general.string {
                            input = pasted
                        }
                    }
                }
                .font(.caption)
            }

            Section("Unlock Bundle") {
                PasswordEntryView(
                    mode: .recover,
                    label: $label,
                    password: $password,
                    showsLabel: false
                )
            }

            if !manualDiscoveryURL.isEmpty {
                Section("Manual Discovery URL") {
                    TextField("http://server:8080", text: $manualDiscoveryURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }

            if let progressMessage {
                Section("Progress") {
                    Text(progressMessage)
                        .font(.footnote)
                }
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Recover") {
                    Task { await runRecovery() }
                }
                .disabled(isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("Recover Access")
        .onAppear {
            if let initialInput, input.isEmpty {
                input = initialInput
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRCodeScannerView(
                    onScan: { scanned in
                        input = scanned
                        showScanner = false
                    },
                    onCancel: { showScanner = false },
                    validationMode: .recoveryBundle
                )
            }
        }
        .alert("Replace used recovery key?", isPresented: $showReplacePrompt) {
            Button("Not now", role: .cancel) {
                onCompleted()
            }
            Button("Replace now") {
                Task { await replaceUsedRecoveryKey() }
            }
        } message: {
            Text("For security, revoke the used recovery key and create a new one.")
        }
    }

    // Executes recover path and exposes manual discovery fallback when the original endpoint is unreachable.
    private func runRecovery() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await manager.recover(
                input: input,
                password: password,
                discoveryURLOverride: manualDiscoveryURL.isEmpty ? nil : manualDiscoveryURL
            ) { message in
                Task { @MainActor in
                    progressMessage = message
                }
            }
            completedRecovery = result
            showReplacePrompt = true
        } catch ConfigurationError.discoveryFetchFailed {
            errorMessage = "Discovery endpoint unreachable. Enter a new discovery URL and retry."
            manualDiscoveryURL = manualDiscoveryURL.isEmpty ? "http://replycant.local:8080" : manualDiscoveryURL
        } catch RecoveryKeyManager.Error.alreadyConfiguredDevice {
            errorMessage = "Recovery is blocked on configured devices. Uninstall and reinstall to continue."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Rotates away the used recovery key so one-time recovery material cannot be reused if leaked later.
    private func replaceUsedRecoveryKey() async {
        guard let completedRecovery else {
            onCompleted()
            return
        }
        do {
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            try await manager.deleteRecoveryKey(uuid: completedRecovery.usedRecoveryUUID, repository: repository, gitDB: gitDB)
            guard let serverConfiguration = ServerConfigurationManager.shared.loadConfiguration() else {
                throw RecoveryKeyManager.Error.missingServerConfiguration
            }
            let replacementPassword = PasswordStrength.generate()
            _ = try await manager.createRecoveryKey(
                label: "\(completedRecovery.usedRecoveryLabel)-replacement",
                password: replacementPassword,
                repository: repository,
                gitDB: gitDB,
                serverConfiguration: serverConfiguration
            )
            onCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
