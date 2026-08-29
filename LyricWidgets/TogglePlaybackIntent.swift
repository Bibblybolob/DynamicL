import AppIntents
import SwiftUI
import LyricCore

/// Play/pause toggle run inside the widget extension when the user taps the
/// button on a home-screen widget or the Lock Screen Live Activity.
struct ToggleLyricPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggles playback of the song shown in the OpenLyrics widget.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Optimistic UI flip first so widgets reload instantly…
        let snapshot = SharedNowPlaying.load()
        if let snapshot {
            let current = SharedNowPlaying.playingOverride() ?? snapshot.isPlaying
            SharedNowPlaying.setPlayingOverride(!current)
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
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Controls Spotify playback")
        // Sub-44pt targets silently swallow taps on Live Activities.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Shared transport buttons for the mini-player layout. The intent only
/// writes to the app-group mailbox; the main app performs the Spotify call.
struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.previous)
        return .result()
    }
}

struct SkipTrackButton: View {
    enum Direction {
        case previous
        case next
    }

    let direction: Direction
    var font: Font = .footnote

    var body: some View {
        Group {
            switch direction {
            case .previous:
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                        .font(font)
                }
            case .next:
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .font(font)
                }
            }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(direction == .previous ? "Previous track" : "Next track")
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}
