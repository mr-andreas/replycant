import SwiftUI

// Manages recovery-key lifecycle so users can create, export, and rotate disaster-recovery credentials.
struct RecoveryKeyView: View {
    static let savePromptTitle = "Did you save your recovery key?"
    static let savePromptMessage = "You must save this backup before continuing."
    static let savePromptConfirmLabel = "Yes, I saved it"
    static let savePromptShowAgainLabel = "Show share dialog again"
    static let statusDescription =
        "Protect yourself from being locked out. A recovery key restores access when you can’t use an existing device to connect to your Replycant server."

    enum RecoveryKeyStep {
        case status
        case name
        case password
        case processing
        case error

        var title: String {
            switch self {
            case .status: return "Recovery Key"
            case .name: return "Recovery Key"
            case .password: return "Recovery Key"
            case .processing: return "Creating Key"
            case .error: return "Error"
            }
        }
    }

    @State private var records: [RecoveryKeyManager.RecoveryKeyRecord] = []
    @State private var currentStep: RecoveryKeyStep = .status
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var label = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var createdKey: RecoveryKeyManager.CreatedRecoveryKey?
    @State private var isShowingShareSheet = false
    @State private var isShowingSavePrompt = false

    private let manager = RecoveryKeyManager()

    // Supports deterministic previews for each wizard step without running async repository calls.
    init(preview step: RecoveryKeyStep? = nil) {
        if let step {
            _currentStep = State(initialValue: step)
        }
    }

    var body: some View {
        Group {
            switch currentStep {
            case .status:
                statusView
            case .name:
                nameStepView
            case .password:
                passwordStepView
            case .processing:
                PairingProgressView(
                    isProcessing: true,
                    message: "Creating recovery key..."
                )
            case .error:
                PairingErrorView(
                    title: "Recovery Key Error",
                    message: errorMessage,
                    onRetry: { currentStep = .status },
                    onCancel: { currentStep = .status }
                )
            }
        }
        .navigationTitle(currentStep.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
        .refreshable {
            guard currentStep == .status else { return }
            await refresh()
        }
        .sheet(isPresented: $isShowingShareSheet, onDismiss: {
            if createdKey != nil {
                isShowingSavePrompt = true
            }
        }) {
            if let createdKey {
                ActivityShareSheet(items: shareItems(for: createdKey))
            }
        }
        .alert(Self.savePromptTitle, isPresented: $isShowingSavePrompt) {
            Button(Self.savePromptShowAgainLabel) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    isShowingShareSheet = true
                }
            }
            Button(Self.savePromptConfirmLabel) {
                createdKey = nil
                isShowingSavePrompt = false
            }
        } message: {
            Text(Self.savePromptMessage)
        }
    }

    // Keeps the status/dashboard screen compact while letting users branch into the wizard.
    private var statusView: some View {
        List {
            Section {
                Text(Self.statusDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                if records.isEmpty {
                    Label("No recovery key found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("\(records.count) recovery key(s) configured", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button("Create recovery key") {
                    errorMessage = nil
                    label = ""
                    password = ""
                    confirmPassword = ""
                    createdKey = nil
                    isShowingSavePrompt = false
                    currentStep = .name
                }
                .buttonStyle(PairingPrimaryButtonStyle())
            }

            if !records.isEmpty {
                Section("Existing Recovery Keys") {
                    ForEach(records, id: \.uuid) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.label)
                            Text(record.uuid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteRecords)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // Step 1 gathers a human-readable label that is reused in filenames and exported backup text.
    private var nameStepView: some View {
        VStack(spacing: 24) {
            Spacer()

            PairingStepIndicator(step: 1, of: 2, phase: .sendKey)

            Text("Name this recovery key")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            TextField("Label", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .padding()
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button("Next") {
                    currentStep = .password
                }
                .disabled(!Self.canAdvanceFromName(label: label))
                .buttonStyle(PairingPrimaryButtonStyle(disabled: !Self.canAdvanceFromName(label: label)))

                Button("Back") {
                    currentStep = .status
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Step 2 enforces password selection before any key material is generated or committed.
    private var passwordStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 2, of: 2, phase: .sendKey)

            Text("Set a backup password")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            PasswordEntryView(
                mode: .create,
                password: $password,
                confirmPassword: $confirmPassword
            )
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button("Create recovery key") {
                    Task { await createRecoveryKey() }
                }
                .disabled(!Self.canAdvanceFromPassword(password: password, confirmPassword: confirmPassword) || isLoading)
                .buttonStyle(PairingPrimaryButtonStyle(disabled: !Self.canAdvanceFromPassword(password: password, confirmPassword: confirmPassword) || isLoading))

                Button("Back") {
                    currentStep = .name
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Keeps wizard progression logic pure so tests can assert button enablement without rendering.
    static func canAdvanceFromName(label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Keeps create action disabled until users intentionally confirm matching credentials.
    static func canAdvanceFromPassword(password: String, confirmPassword: String) -> Bool {
        !password.isEmpty && password == confirmPassword
    }

    // Reloads repository-backed key state so settings warnings and row actions stay synchronized.
    private func refresh() async {
        do {
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            records = try manager.listRecoveryKeys(repository: repository)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Creates one new recovery key and keeps it in memory until the user confirms they saved the export.
    private func createRecoveryKey() async {
        errorMessage = nil
        isLoading = true
        currentStep = .processing
        defer { isLoading = false }
        do {
            guard let serverConfiguration = ServerConfigurationManager.shared.loadConfiguration() else {
                throw RecoveryKeyManager.Error.missingServerConfiguration
            }
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            createdKey = try await manager.createRecoveryKey(
                label: label,
                password: password,
                repository: repository,
                gitDB: gitDB,
                serverConfiguration: serverConfiguration
            )
            password = ""
            confirmPassword = ""
            await refresh()
            currentStep = .status
            isShowingShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
            currentStep = .error
        }
    }

    // Deletes selected recovery keys so users can revoke compromised or superseded backups.
    private func deleteRecords(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let record = records[index]
                do {
                    let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
                    let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
                    try await manager.deleteRecoveryKey(uuid: record.uuid, repository: repository, gitDB: gitDB)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            await refresh()
        }
    }

    // Builds share payload text that can be stored with the QR image in password managers and offline backups.
    private func shareItems(for createdKey: RecoveryKeyManager.CreatedRecoveryKey) -> [Any] {
        let host = URL(string: ServerConfigurationManager.shared.loadURL() ?? "")?.host ?? "unknown-host"
        let text = """
        Replycant recovery key
        Label: \(createdKey.label)
        ID: \(createdKey.uuid)
        Server: \(host)
        Deep link: \(createdKey.deepLink)

        Password is required and is not included in this share.
        """
        let textSource = RecoveryShareText(
            plainText: text,
            label: createdKey.label
        )
        let qrImage = QRCodeDisplayView.generateQRCodeImage(
            from: createdKey.envelopeJSON,
            side: 1024,
            correctionLevel: "H"
        )
        if let qrImage {
            let cardImage = RecoveryShareCard.render(
                qr: qrImage,
                label: createdKey.label,
                uuid: createdKey.uuid,
                host: host
            )
            return [textSource, RecoveryShareImage(image: cardImage)]
        }
        return [textSource]
    }
}

#Preview("Status") {
    NavigationStack {
        RecoveryKeyView(preview: .status)
    }
}

#Preview("Name Step") {
    NavigationStack {
        RecoveryKeyView(preview: .name)
    }
}
