//
//  SettingsView.swift
//  iosapp
//
//  Created by Andreas on 2025-10-16.
//

import SwiftUI

// Container view for development settings pages.
// Provides navigation to various settings pages such as repository management, cache controls, and git plumbing.
struct SettingsView: View {
    let onWipeAndResync: () -> Void
    @State private var isShowingResetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: DeviceLinkingView()) {
                        Label("Link a New Device", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Device Management")
                }
                
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
}


