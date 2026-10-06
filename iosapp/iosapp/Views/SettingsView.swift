//
//  SettingsView.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import LibGit2
import SwiftUI

// Container view for development settings pages.
// Provides navigation to various settings pages such as repository management, cache controls, and git plumbing.
struct SettingsView: View {
    let onWipeAndResync: () -> Void
    let showRecoveryWarning: Bool
    @State private var isShowingResetConfirmation = false
    @State private var hasLoadedTailnet = false
    @State private var isTailnetConfigured = false
    @State private var tailnetReport: TailnetStatusReport?
    @ObservedObject private var databaseCompatibility = DatabaseCompatibilityManager.shared

    // Allows callers to surface repo-wide recovery readiness in the settings navigation row.
    init(onWipeAndResync: @escaping () -> Void, showRecoveryWarning: Bool = false) {
        self.onWipeAndResync = onWipeAndResync
        self.showRecoveryWarning = showRecoveryWarning
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: DeviceLinkingView()) {
                        Label("Link a New Device", systemImage: "plus.circle")
                    }

                    NavigationLink(destination: RecoveryKeyView()) {
                        HStack {
                            Label("Recovery Key", systemImage: "key")
                            Spacer()
                            if showRecoveryWarning {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Device Management")
                }

                // Loaded here, not inside the section, because a zero-height
                // List child never runs `.task` and a joined device then
                // looks unpaired. Above Advanced because "can
                // this device reach the library at all" is what a user
                // checks first when a sync fails.
                connectionSection

                Section {
                    NavigationLink(destination: RepositorySettingsView()) {
                        Label("Repository", systemImage: "arrow.triangle.branch")
                    }

                    NavigationLink(destination: SyncSettingsView()) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }

                    NavigationLink(destination: PlaybackSettingsView()) {
                        Label("Playback", systemImage: "play.rectangle")
                    }
                    
                    NavigationLink(destination: CacheSettingsView()) {
                        Label("Cache", systemImage: "photo.stack")
                    }
                } header: {
                    Text("Advanced")
                }

                if databaseCompatibility.incompatibility == nil {
                    Section {
                        Button(role: .destructive) {
                            isShowingResetConfirmation = true
                        } label: {
                            Label("Reset & Resync", systemImage: "arrow.clockwise.circle")
                        }
                    } footer: {
                        Text("Deletes all local repository state and clones fresh data from server while preserving device keys.")
                    }
                }
            }
            .task {
                isTailnetConfigured = await TailnetBootstrap.shared.isConfigured
                tailnetReport = await TailnetBootstrap.shared.status()
                hasLoadedTailnet = true
            }
            .navigationTitle("Settings")
            .alert("Reset Local State?", isPresented: $isShowingResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset & Resync", role: .destructive) {
                    onWipeAndResync()
                }
            } message: {
                Text("This will remove local repository data and download it again from the server.")
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch TailnetConnectionSection.presentation(
            hasLoaded: hasLoadedTailnet,
            isConfigured: isTailnetConfigured,
            report: tailnetReport
        ) {
        case .hidden:
            EmptyView()
        case .unavailable:
            Section {
                LabeledContent("Status") {
                    Text("Unavailable")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Connection")
            }
        case .report(let report):
            Section {
                TailnetConnectionSection(report: report)
            } header: {
                Text("Connection")
            } footer: {
                Text(TailnetConnectionSection.footer(for: report.controlRoute))
            }
        }
    }
}


