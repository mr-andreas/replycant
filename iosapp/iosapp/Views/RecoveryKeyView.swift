import SwiftUI
import UIKit

// Manages recovery-key lifecycle so users can create, export, and rotate disaster-recovery credentials.
struct RecoveryKeyView: View {
    static let statusDescription =
        "Protect yourself from being locked out. A recovery key restores access when you can’t use an existing device to connect to your Replycant server."
    static let nameStepHeading = "Name this recovery key"
    static let nameStepSubtitle =
        "This label appears in Settings and in the backup you save."
    static let passwordStepHeading = "Set a backup password"
    static let passwordStepSubtitle =
        "This password encrypts the backup and cannot be reset. You will need it to recover access."
    static let passwordMismatchMessage = "Passwords do not match."
    static let createdStepHeading = "Recovery key created"
    static let createdStepBody =
        "Save this backup outside this device. The password is not included."
    static let createdStepShareLabel = "Share recovery key"
    static let createdStepDoneLabel = "Done"

    enum RecoveryKeyStep {
        case status
        case name
        case password
        case processing
        case created
        case error

        var title: String {
            switch self {
            case .status: return "Recovery Key"
            case .name: return "Recovery Key"
            case .password: return "Recovery Key"
            case .processing: return "Creating Key"
            case .created: return "Recovery Key Created"
            case .error: return "Error"
            }
        }
    }

    @State private var records: [RecoveryKeyManager.RecoveryKeyRecord] = []
    @State private var currentStep: RecoveryKeyStep = .status
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var label = Self.defaultLabel()
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var createdKey: RecoveryKeyManager.CreatedRecoveryKey?
    @State private var isShowingShareSheet = false
    @State private var hasSharedCreatedKey = false

    private let manager = RecoveryKeyManager()
    // Keeps Canvas from touching libgit2, which is not initialized in previews.
    private let isPreview: Bool

    // Supports deterministic previews for each wizard step without running async repository calls.
    init(preview step: RecoveryKeyStep? = nil) {
        isPreview = step != nil
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
            case .created:
                createdStepView
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
        .navigationBarBackButtonHidden(currentStep != .status)
        .toolbar {
            if let destination = Self.backDestination(from: currentStep) {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        currentStep = destination
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .background {
            InteractivePopGestureController(isEnabled: currentStep == .status)
        }
        .task {
            guard !isPreview else { return }
            await refresh()
        }
        .refreshable {
            guard currentStep == .status, !isPreview else { return }
            await refresh()
        }
        .sheet(isPresented: $isShowingShareSheet, onDismiss: {
            hasSharedCreatedKey = true
        }) {
            if let createdKey {
                ActivityShareSheet(items: shareItems(for: createdKey))
            }
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
                    label = Self.defaultLabel()
                    password = ""
                    confirmPassword = ""
                    createdKey = nil
                    hasSharedCreatedKey = false
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
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 1, of: 2, phase: .sendKey)

            Text(Self.nameStepHeading)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(Self.nameStepSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            TextField("Label", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .pairingFieldBackground()
                .padding(.horizontal)

            Spacer()

            Button("Next") {
                currentStep = .password
            }
            .disabled(!Self.canAdvanceFromName(label: label))
            .buttonStyle(PairingPrimaryButtonStyle(disabled: !Self.canAdvanceFromName(label: label)))
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Step 2 enforces password selection before any key material is generated or committed.
    private var passwordStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            PairingStepIndicator(step: 2, of: 2, phase: .sendKey)

            Text(Self.passwordStepHeading)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(Self.passwordStepSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            PasswordEntryView(
                mode: .create,
                password: $password,
                confirmPassword: $confirmPassword
            )
            .padding(.horizontal)

            if let warning = Self.passwordWarning(password: password, confirmPassword: confirmPassword) {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Create recovery key") {
                Task { await createRecoveryKey() }
            }
            .disabled(!Self.canAdvanceFromPassword(password: password, confirmPassword: confirmPassword) || isLoading)
            .buttonStyle(PairingPrimaryButtonStyle(disabled: !Self.canAdvanceFromPassword(password: password, confirmPassword: confirmPassword) || isLoading))
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Holds the user on a dedicated save step so the key cannot be left
    // behind on this device without first opening the share sheet.
    private var createdStepView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text(Self.createdStepHeading)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(Self.createdStepBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(Self.createdStepShareLabel) {
                    isShowingShareSheet = true
                }
                .buttonStyle(PairingPrimaryButtonStyle())

                Button(Self.createdStepDoneLabel) {
                    createdKey = nil
                    hasSharedCreatedKey = false
                    currentStep = .status
                }
                .disabled(!Self.canDismissCreatedKey(hasShared: hasSharedCreatedKey))
                .buttonStyle(
                    PairingPrimaryButtonStyle(
                        disabled: !Self.canDismissCreatedKey(hasShared: hasSharedCreatedKey)
                    )
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    // Keeps wizard back navigation one step at a time so the chevron never
    // skips from a create step straight out to Settings.
    static func backDestination(from step: RecoveryKeyStep) -> RecoveryKeyStep? {
        switch step {
        case .status, .processing, .created:
            return nil
        case .name, .error:
            return .status
        case .password:
            return .name
        }
    }

    // Prefills the name field with the current device so users can accept a
    // recognizable default instead of inventing a label from scratch.
    static func defaultLabel() -> String {
        UIDevice.current.name
    }

    // Keeps wizard progression logic pure so tests can assert button enablement without rendering.
    static func canAdvanceFromName(label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Keeps create action disabled until users intentionally confirm matching credentials.
    static func canAdvanceFromPassword(password: String, confirmPassword: String) -> Bool {
        !password.isEmpty && password == confirmPassword
    }

    // Keeps Done disabled until the share sheet has been opened, so the
    // created key cannot be dismissed without a save attempt.
    static func canDismissCreatedKey(hasShared: Bool) -> Bool {
        hasShared
    }

    // Shows mismatch copy only after both fields are filled and disagree,
    // so empty or in-progress entry is not treated as an error.
    static func passwordWarning(password: String, confirmPassword: String) -> String? {
        guard !password.isEmpty, !confirmPassword.isEmpty, password != confirmPassword else {
            return nil
        }
        return passwordMismatchMessage
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
            currentStep = .created
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

// Blocks the system edge-swipe while the create wizard is mid-flow so a
// swipe cannot skip steps and pop straight back to Settings.
private struct InteractivePopGestureController: UIViewControllerRepresentable {
    let isEnabled: Bool

    // Hosts an invisible controller so the pop-gesture flag can reach UIKit.
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    // Pushes the latest enabled flag after SwiftUI updates the wizard step.
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isPopEnabled = isEnabled
    }

    // Applies the pop-gesture flag on the hosting navigation controller.
    final class Controller: UIViewController {
        var isPopEnabled = true {
            didSet { apply() }
        }

        // Applies the flag once this controller is actually in the nav stack.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        // Restores swipe-back for Settings after this wizard leaves the stack.
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        // Re-reads the current flag after the controller joins the nav stack.
        private func apply() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = isPopEnabled
        }
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

#Preview("Password Step") {
    NavigationStack {
        RecoveryKeyView(preview: .password)
    }
}

#Preview("Created") {
    NavigationStack {
        RecoveryKeyView(preview: .created)
    }
}
