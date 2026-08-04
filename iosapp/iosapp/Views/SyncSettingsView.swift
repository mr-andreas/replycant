import SwiftUI

// Configures background push/pull cadence so users can tune periodic git synchronization.
struct SyncSettingsView: View {
    @State private var isPushEnabled = SyncSettingsManager.shared.isPushEnabled
    @State private var pushIntervalSeconds = SyncSettingsManager.shared.pushIntervalSeconds
    @State private var isPullEnabled = SyncSettingsManager.shared.isPullEnabled
    @State private var pullIntervalSeconds = SyncSettingsManager.shared.pullIntervalSeconds

    var body: some View {
        Form {
            Section("Push") {
                Toggle("Enable periodic push", isOn: $isPushEnabled)
                    .onChange(of: isPushEnabled) { _, newValue in
                        SyncSettingsManager.shared.isPushEnabled = newValue
                    }

                Stepper(value: $pushIntervalSeconds, in: 1...30, step: 1) {
                    Text("Push interval: \(Int(pushIntervalSeconds))s")
                }
                .disabled(!isPushEnabled)
                .onChange(of: pushIntervalSeconds) { _, newValue in
                    SyncSettingsManager.shared.pushIntervalSeconds = newValue
                }
            }

            Section("Pull") {
                Toggle("Enable periodic pull", isOn: $isPullEnabled)
                    .onChange(of: isPullEnabled) { _, newValue in
                        SyncSettingsManager.shared.isPullEnabled = newValue
                    }

                Stepper(value: $pullIntervalSeconds, in: 1...30, step: 1) {
                    Text("Pull interval: \(Int(pullIntervalSeconds))s")
                }
                .disabled(!isPullEnabled)
                .onChange(of: pullIntervalSeconds) { _, newValue in
                    SyncSettingsManager.shared.pullIntervalSeconds = newValue
                }
            }
        }
        .navigationTitle("Sync")
    }
}
