import WidgetKit
import SwiftUI
import AppIntents
import LyricCore

/// Shows or hides the phone-owned lyric session from Control Center. The app
/// consumes the request so Spotify authorization and ActivityKit work stay in
/// one serialized pipeline.
@available(iOS 18.0, *)
struct StartLyricsSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.jonathantran.dynamicallyrics.start-lyrics",
            provider: LiveActivityControlValueProvider()
        ) { isOn in
            ControlWidgetToggle(
                isOn: isOn,
                action: LiveActivityControlIntent()
            ) {
                Label("Lyrics", systemImage: "quote.bubble")
            } valueLabel: { enabled in
                Text(enabled ? "On" : "Off")
            }
        }
        .displayName("OpenLyrics")
        .description("Show or hide lyrics on the Lock Screen and Dynamic Island.")
    }
}

@available(iOS 18.0, *)
private struct LiveActivityControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharedNowPlaying.liveActivityControlEnabled()
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
