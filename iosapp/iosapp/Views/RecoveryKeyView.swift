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
        "Save this recovery key somewhere safe. The password needed to unlock it is not included, so keep it separately."
    static let createdStepShareLabel = "Share recovery key"
    static let createdStepShareAgainLabel = "Share again"
    static let createdStepDoneLabel = "Done"
    static let deleteButtonLabel = "Delete"
    static let deleteConfirmationBody =
        "This recovery key stops working immediately and cannot be undone."
    static let deleteConfirmActionLabel = "Delete Key"
    static let deleteCancelLabel = "Cancel"

    // Names each create-wizard screen so routing and titles stay explicit.
    // CaseIterable lets the screen gallery fail a test when a new step is
    // added without a corresponding canvas tile.
    enum RecoveryKeyStep: CaseIterable {
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
    @State private var hasSharedCreatedKey = false
    @State private var shareBundle: RecoveryShareBundle?
    @State private var pendingDeletion: RecoveryKeyManager.RecoveryKeyRecord?
    @State private var deletingUUIDs: Set<String> = []

    // Parks the repository-backed list so gallery tiles can show
    // configured keys, an in-flight revoke, and a failed revoke
    // without reading pubkeys/ or pushing to the server.
    struct PreviewState {
        var records: [RecoveryKeyManager.RecoveryKeyRecord]
        var deletingUUIDs: Set<String> = []
        var errorMessage: String? = nil

        // Two labeled keys so the status screen can show a configured
        // list instead of the empty warning.
        static let keysListed = PreviewState(records: sampleRecords)

        // Marks one listed key as in-flight so the row spinner is
        // visible without starting a revoke.
        static let deleting = PreviewState(
            records: sampleRecords,
            deletingUUIDs: [sampleRecords[0].uuid]
        )

        // Keeps the list on screen with a revoke error so the red
        // footnote is reviewable without a failed push.
        static let deleteFailed = PreviewState(
            records: sampleRecords,
            errorMessage: "Failed to revoke recovery key"
        )

        // Shared synthetic keys so listed, deleting, and failed tiles
        // stay visually comparable.
        private static let sampleRecords = [
            RecoveryKeyManager.RecoveryKeyRecord(
                label: "home-safe",
                uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                pubPath: "pubkeys/home-safe-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.recovery.pub",
                agePath: "pubkeys/home-safe-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.recovery.age"
            ),
            RecoveryKeyManager.RecoveryKeyRecord(
                label: "office-drawer",
                uuid: "11111111-2222-3333-4444-555555555555",
                pubPath: "pubkeys/office-drawer-11111111-2222-3333-4444-555555555555.recovery.pub",
                agePath: "pubkeys/office-drawer-11111111-2222-3333-4444-555555555555.recovery.age"
            )
        ]
    }

    private let manager = RecoveryKeyManager()
    // Keeps Canvas from touching libgit2, which is not initialized in previews.
    private let isPreview: Bool

    // Supports deterministic previews for each wizard step and parked
    // list/delete states without running async repository calls.
    init(
        preview step: RecoveryKeyStep? = nil,
        hasShared: Bool = false,
        previewState: PreviewState? = nil
    ) {
        isPreview = step != nil || previewState != nil
        if let step {
            _currentStep = State(initialValue: step)
        }
        _hasSharedCreatedKey = State(initialValue: hasShared)
        if let previewState {
            _records = State(initialValue: previewState.records)
            _deletingUUIDs = State(initialValue: previewState.deletingUUIDs)
            _errorMessage = State(initialValue: previewState.errorMessage)
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
        .sheet(item: $shareBundle, onDismiss: {
            hasSharedCreatedKey = true
        }) { bundle in
            ActivityShareSheet(items: bundle.items)
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
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.label)
                                Text(record.uuid)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if Self.isDeleting(uuid: record.uuid, in: deletingUUIDs) {
                                ProgressView()
                            } else {
                                Button(role: .destructive) {
                                    pendingDeletion = record
                                } label: {
                                    Label(Self.deleteButtonLabel, systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    Self.deleteAccessibilityLabel(label: record.label)
                                )
                            }
                        }
                    }
                    .onDelete(perform: confirmDeleteRecords)
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
        .alert(
            pendingDeletion.map { Self.deleteConfirmationTitle(label: $0.label) } ?? "",
            isPresented: isDeleteConfirmationPresented,
            presenting: pendingDeletion
        ) { record in
            Button(Self.deleteCancelLabel, role: .cancel) {}
            Button(Self.deleteConfirmActionLabel, role: .destructive) {
                Task { await deleteRecord(record) }
            }
        } message: { _ in
            Text(Self.deleteConfirmationBody)
        }
    }

    // Bridges the optional pending key into alert's isPresented flag so
    // swipe and the trash button share one confirmation.
    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
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

            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.brandGreen)

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
                createdStepShareButton

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

    // Swaps Share from the required purple CTA to a quieter repeat action
    // so Done is the only primary button after the first share attempt.
    private var createdStepShareButton: some View {
        let title = Self.createdStepShareTitle(hasShared: hasSharedCreatedKey)
        let shareButton = Button(title) {
            if let createdKey {
                shareBundle = makeShareBundle(for: createdKey)
            }
        }
        return Group {
            if hasSharedCreatedKey {
                shareButton.buttonStyle(PairingTertiaryButtonStyle())
            } else {
                shareButton.buttonStyle(PairingPrimaryButtonStyle())
            }
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

    // Relabels the share action after a first attempt so the button reads as
    // an optional repeat rather than a still-pending required step.
    static func createdStepShareTitle(hasShared: Bool) -> String {
        hasShared ? createdStepShareAgainLabel : createdStepShareLabel
    }

    // Names the key in the confirmation title so users know which backup
    // they are about to revoke.
    static func deleteConfirmationTitle(label: String) -> String {
        "Delete “\(label)”?"
    }

    // Distinguishes trash buttons when several keys are listed.
    static func deleteAccessibilityLabel(label: String) -> String {
        "Delete recovery key \(label)"
    }

    // Drives the per-row spinner so only the in-flight revoke shows busy.
    static func isDeleting(uuid: String, in deletingUUIDs: Set<String>) -> Bool {
        deletingUUIDs.contains(uuid)
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

    // Routes swipe-to-delete through the same confirmation as the trash
    // button so a swipe cannot revoke a key without naming it first.
    private func confirmDeleteRecords(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        pendingDeletion = records[index]
    }

    // Revokes one recovery key by uuid so a later refresh cannot delete
    // the wrong row if the list changes mid-push.
    private func deleteRecord(_ record: RecoveryKeyManager.RecoveryKeyRecord) async {
        errorMessage = nil
        deletingUUIDs.insert(record.uuid)
        defer { deletingUUIDs.remove(record.uuid) }
        do {
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            try await manager.deleteRecoveryKey(
                uuid: record.uuid,
                repository: repository,
                gitDB: gitDB
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Builds the text and image items from the created key so the
    // share sheet can offer a deep-link backup plus a QR card.
    private func makeShareBundle(
        for createdKey: RecoveryKeyManager.CreatedRecoveryKey
    ) -> RecoveryShareBundle {
        let host = URL(string: ServerConfigurationManager.shared.loadURL() ?? "")?.host ?? "unknown-host"
        let text = RecoveryShareText.compose(
            label: createdKey.label,
            uuid: createdKey.uuid,
            host: host,
            deepLink: createdKey.deepLink
        )
        let qrImage = QRCodeDisplayView.generateQRCodeImage(
            from: createdKey.envelopeJSON,
            side: 1024,
            correctionLevel: "H"
        )
        let cardImage = qrImage.map { qr in
            RecoveryShareCard.render(
                qr: qr,
                label: createdKey.label,
                uuid: createdKey.uuid,
                host: host
            )
        }
        return RecoveryShareBundle(
            plainText: text,
            label: createdKey.label,
            cardImage: cardImage
        )
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

#Preview("Created After Share") {
    NavigationStack {
        RecoveryKeyView(preview: .created, hasShared: true)
    }
}
