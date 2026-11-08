import SwiftUI

// Lists every device that can open this library and removes any device
// except this one, so a lost phone can be cut off from new photos.
struct AuthorizedDevicesView: View {
    static let navigationTitle = "Devices"
    static let thisDeviceLabel = "This device"
    static let removeButtonLabel = "Remove"
    static let removeConfirmActionLabel = "Remove"
    static let removeCancelLabel = "Cancel"
    static let removeConfirmationBody =
        "This device loses access to the library immediately. Photos added from now on use a new encryption key it never receives."

    // Names the device in the confirmation so a library with several
    // devices cannot be revoked by a tap on the wrong row.
    static func removeConfirmationTitle(name: String) -> String {
        "Remove “\(name)”?"
    }

    // Distinguishes trash buttons when several devices are listed.
    static func removeAccessibilityLabel(name: String) -> String {
        "Remove \(name)"
    }

    // Drives the per-row spinner so only the device being removed looks busy.
    static func isRevoking(pubPath: String, in revokingPaths: Set<String>) -> Bool {
        revokingPaths.contains(pubPath)
    }

    // Parks a device list so gallery tiles can show a removal in flight
    // and a failed removal without reading pubkeys/ or pushing.
    struct PreviewState {
        var records: [AuthorizedDeviceManager.DeviceRecord]
        var revokingPaths: Set<String> = []
        var errorMessage: String? = nil

        // This phone plus one other device, so the row that cannot be
        // removed sits next to a row that can.
        static let listed = PreviewState(records: sampleRecords)

        // Marks the other device as in flight so the row spinner is
        // visible without starting a removal.
        static let revoking = PreviewState(
            records: sampleRecords,
            revokingPaths: [sampleRecords[1].pubPath]
        )

        // Keeps the list on screen with a removal error so the red
        // footnote is reviewable without a failed push.
        static let revokeFailed = PreviewState(
            records: sampleRecords,
            errorMessage: "Failed to remove device"
        )

        private static let sampleRecords = [
            AuthorizedDeviceManager.DeviceRecord(
                name: "iphone-15-pro",
                uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                pubPath: "pubkeys/iphone-15-pro-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pub",
                agePath: "pubkeys/iphone-15-pro-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.age",
                isCurrentDevice: true
            ),
            AuthorizedDeviceManager.DeviceRecord(
                name: "kitchen-ipad",
                uuid: "11111111-2222-3333-4444-555555555555",
                pubPath: "pubkeys/kitchen-ipad-11111111-2222-3333-4444-555555555555.pub",
                agePath: "pubkeys/kitchen-ipad-11111111-2222-3333-4444-555555555555.age",
                isCurrentDevice: false
            )
        ]
    }

    @State private var records: [AuthorizedDeviceManager.DeviceRecord] = []
    @State private var errorMessage: String?
    @State private var pendingRemoval: AuthorizedDeviceManager.DeviceRecord?
    @State private var revokingPaths: Set<String> = []

    private let manager = AuthorizedDeviceManager()
    // Keeps Canvas from touching libgit2, which is not initialized in previews.
    private let isPreview: Bool

    init(previewState: PreviewState? = nil) {
        isPreview = previewState != nil
        if let previewState {
            _records = State(initialValue: previewState.records)
            _revokingPaths = State(initialValue: previewState.revokingPaths)
            _errorMessage = State(initialValue: previewState.errorMessage)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(records, id: \.pubPath) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                            if let uuid = record.uuid {
                                Text(uuid)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if record.isCurrentDevice {
                            Text(Self.thisDeviceLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if Self.isRevoking(pubPath: record.pubPath, in: revokingPaths) {
                            ProgressView()
                        } else {
                            Button(role: .destructive) {
                                pendingRemoval = record
                            } label: {
                                Label(Self.removeButtonLabel, systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Self.removeAccessibilityLabel(name: record.name))
                        }
                    }
                    .deleteDisabled(record.isCurrentDevice)
                }
                .onDelete(perform: confirmDelete)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Self.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !isPreview else { return }
            await refresh()
        }
        .refreshable {
            guard !isPreview else { return }
            await refresh()
        }
        .alert(
            pendingRemoval.map { Self.removeConfirmationTitle(name: $0.name) } ?? "",
            isPresented: isRemovalConfirmationPresented,
            presenting: pendingRemoval
        ) { record in
            Button(Self.removeCancelLabel, role: .cancel) {}
            Button(Self.removeConfirmActionLabel, role: .destructive) {
                Task { await revoke(record) }
            }
        } message: { _ in
            Text(Self.removeConfirmationBody)
        }
    }

    // Bridges the optional pending device into alert's isPresented flag
    // so swipe and the trash button share one confirmation.
    private var isRemovalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    // Reloads the key list so a removal that just landed, or a key added
    // by another device, shows up without leaving Settings.
    private func refresh() async {
        do {
            let repository = try await MainActor.run {
                try RepositoryManager.shared.getRepository()
            }
            records = try manager.listDevices(repository: repository)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Routes swipe-to-delete through the same confirmation as the trash
    // button, and ignores this phone even if the row is offered.
    private func confirmDelete(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        let record = records[index]
        guard !record.isCurrentDevice else { return }
        pendingRemoval = record
    }

    // Removes one device by its pubkey path so a refresh during the
    // push cannot delete a different row than the one that was confirmed.
    private func revoke(_ record: AuthorizedDeviceManager.DeviceRecord) async {
        errorMessage = nil
        revokingPaths.insert(record.pubPath)
        defer { revokingPaths.remove(record.pubPath) }
        do {
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            try await manager.revokeDevice(pubPath: record.pubPath, gitDB: gitDB)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Listed") {
    NavigationStack {
        AuthorizedDevicesView(previewState: .listed)
    }
}

#Preview("Revoking") {
    NavigationStack {
        AuthorizedDevicesView(previewState: .revoking)
    }
}

#Preview("Revoke Failed") {
    NavigationStack {
        AuthorizedDevicesView(previewState: .revokeFailed)
    }
}
