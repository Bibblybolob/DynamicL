import WidgetKit
import SwiftUI
import AppIntents
import LyricCore

/// Starts a phone-owned lyric session from Control Center or a Shortcuts
/// automation. The app consumes this one-shot request when it opens.
@available(iOS 18.0, *)
struct StartLyricsSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Lyrics Session"
    static let description = IntentDescription("Starts the OpenLyrics Live Activity for the current Spotify song.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedNowPlaying.requestLocalSessionStart()
        PlaybackCommandBus.send(.refresh)
        return .result()
    }
}

/// A direct iOS 18 entry point. It avoids the first-use "Show Lyrics" step
/// after the user adds the control and permits the same action in Shortcuts.
@available(iOS 18.0, *)
struct StartLyricsSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.jonathantran.dynamicallyrics.start-lyrics") {
            ControlWidgetButton(action: StartLyricsSessionIntent()) {
                Label("Start Lyrics", systemImage: "quote.bubble")
            }
        }
        .displayName("OpenLyrics")
        .description("Start lyrics for the current Spotify song.")
    }
}

@main
struct LyricWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CurrentLineWidget()
        AlbumPlayerWidget()
        LyricFocusWidget()
        MinimalLyricsWidget()
        AlbumCardWidget()
        KaraokeFocusWidget()
        LyricsPosterWidget()
        WaveformPlayerWidget()
        AlbumStackWidget()
        LockscreenLyricWidget()
        LockscreenAlbumWidget()
        LockscreenQuoteWidget()
        VinylWidget()
        LyricsLiveActivity()
        if #available(iOS 18.0, *) {
            StartLyricsSessionControl()
        }
    }
}
