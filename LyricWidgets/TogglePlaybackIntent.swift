import AppIntents
import SwiftUI
import LyricCore

/// Play/pause toggle run inside the widget extension when the user taps the
/// button on a home-screen widget or the Lock Screen Live Activity.
struct ToggleLyricPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggles playback of the song shown in the Dynamicallyrics widget.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Optimistic UI flip first so widgets reload instantly…
        let snapshot = SharedNowPlaying.load()
        if let snapshot {
            SharedNowPlaying.setPlayingOverride(!snapshot.isPlaying)
        }

        // …then hand the real work to the app via the shared command mailbox.
        PlaybackCommandBus.send(.togglePlayPause)

        return .result()
    }
}

/// Shared play/pause button used by widget + Live Activity surfaces.
struct TogglePlaybackButton: View {
    let isPlaying: Bool
    var font: Font = .title3

    var body: some View {
        Button(intent: ToggleLyricPlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(font)
                .fontWeight(.semibold)
        }
        .buttonStyle(.plain)
    }
}
