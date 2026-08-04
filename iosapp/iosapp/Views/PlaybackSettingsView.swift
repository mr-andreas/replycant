import SwiftUI

// Exposes playback-method controls so users can opt into transcoding while the
// app still defaults to direct play.
struct PlaybackSettingsView: View {
    @State private var playbackMethod = PlaybackSettingsManager.shared.playbackMethod

    // Renders playback controls in one focused form section to keep strategy
    // changes explicit and discoverable in advanced settings.
    var body: some View {
        Form {
            Section {
                Picker("Playback Method", selection: $playbackMethod) {
                    Text("Direct Play").tag(PlaybackMethod.directPlay)
                    Text("Transcode").tag(PlaybackMethod.transcode)
                }
                .pickerStyle(.segmented)
                .onChange(of: playbackMethod) { _, newValue in
                    PlaybackSettingsManager.shared.playbackMethod = newValue
                }
            } header: {
                Text("Video Playback")
            } footer: {
                Text("Direct Play is default. Adaptive bandwidth selection will be added in a future update.")
            }
        }
        .navigationTitle("Playback")
    }
}
