import AppIntents
import LyricCore

/// Enables the Live Activity through a Shortcuts automation. The first use
/// intentionally leaves the Lock Screen action visible, matching the public
/// Dynamic Lyrics workflow. The user presses Show Lyrics once to hand the
/// lyric session to the foreground app.
struct EnableLiveActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Live Activity Lyrics"
    static let description = IntentDescription(
        "Enables OpenLyrics on the Lock Screen for the current Spotify song."
    )
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedNowPlaying.requestLiveActivityEnable()
        return .result()
    }
}

/// Publishes the first-use enable flow used by the Live Activity switch.
/// The Control Center quick toggle uses the separate direct-start intent.
struct OpenLyricsShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: EnableLiveActivityIntent(),
                phrases: [
                    "Open live activity lyrics in \(.applicationName)",
                    "Enable live activity lyrics in \(.applicationName)"
                ],
                shortTitle: "Open Live Activity Lyrics",
                systemImageName: "quote.bubble"
            )
            AppShortcut(
                intent: StartLyricsSessionIntent(),
                phrases: [
                    "Start lyrics in \(.applicationName)",
                    "Show lyrics in \(.applicationName)"
                ],
                shortTitle: "Start Lyrics",
                systemImageName: "play.circle"
            )
    }
}
