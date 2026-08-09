import SwiftUI

// Manages recovery-key lifecycle so users can create, export, and rotate disaster-recovery credentials.
struct RecoveryKeyView: View {
    @State private var records: [RecoveryKeyManager.RecoveryKeyRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var label = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var createdKey: RecoveryKeyManager.CreatedRecoveryKey?
    @State private var isShowingShareSheet = false
    @State private var didConfirmSaved = false

    private let manager = RecoveryKeyManager()

    var body: some View {
        List {
            Section("Status") {
                if records.isEmpty {
                    Label("No recovery key found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("\(records.count) recovery key(s) configured", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                }
            }

            Section("Create Recovery Key") {
                TextField("Label", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                PasswordEntryView(
                    mode: .create,
                    label: $label,
                    password: $password,
                    confirmPassword: $confirmPassword,
                    showsLabel: false,
                    onGenerate: {
                        let generated = PasswordStrength.generate()
                        password = generated
                        confirmPassword = generated
                    }
                )
                Button("Create and Prepare Share") {
                    Task { await createRecoveryKey() }
                }
                .disabled(isLoading || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || password != confirmPassword)
            }

            if let createdKey {
                Section("Share and Confirm Saved") {
                    QRCodeDisplayView(
                        data: createdKey.envelopeJSON,
                        title: "Recovery key backup",
                        subtitle: "Scan in app recovery on another device.",
                        qrSide: 260,
                        correctionLevel: "H"
                    )
                    .frame(maxWidth: .infinity)

                    Button("Share backup") {
                        isShowingShareSheet = true
                    }

                    Toggle("I have saved this recovery key", isOn: $didConfirmSaved)
                    Button("Done") {
                        self.createdKey = nil
                        didConfirmSaved = false
                    }
                    .disabled(!didConfirmSaved)
                }
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
        .navigationTitle("Recovery Key")
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let createdKey {
                ActivityShareSheet(items: shareItems(for: createdKey))
            }
        }
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
        } catch {
            errorMessage = error.localizedDescription
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
        let qrImage = QRCodeDisplayView.generateQRCodeImage(from: createdKey.envelopeJSON, side: 1024, correctionLevel: "H")
        if let qrImage {
            return [text, qrImage]
        }
        return [text]
    }
}
