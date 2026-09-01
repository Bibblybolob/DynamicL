import AppIntents
import ActivityKit
import SwiftUI
import LyricCore

/// Runs when the user taps the ↻ button that appears on the Lock Screen
/// activity once its content goes stale. Routes through the shared mailbox
/// like the play/pause intent — the extension has no Spotify access of its
/// own, so the action foregrounds OpenLyrics before the app polls Spotify.
struct RefreshLyricsActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh"
    static let description = IntentDescription("Forces an immediate playback poll so lyrics catch up.")

    /// A stale Live Activity can be shown while the app is suspended or has
    /// been terminated. On iOS 26 and later, foreground the app for this
    /// recovery action so the mailbox is consumed by AppModel immediately.
    /// A background-only intent could write the command successfully while
    /// leaving the app's ticker asleep, which made the refresh button appear
    /// to do nothing. The older flag keeps the same behavior on iOS 17–25.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    // The stall scenarios this button exists for are exactly the ones where
    // the main app may be dead. LiveActivityIntent launches the app process
    // for the handoff; the legacy flag preserves that behavior on older OS
    // versions.
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Refresh is a recovery command, not the first-use activation. Only
        // Show Lyrics may opt the user into the phone-owned lyric session.
        // Mailbox command for the app's tick loop…
        PlaybackCommandBus.send(.refresh)
        // …plus a receipt in the shared defaults so a silent failure on the
        // app side is diagnosable (the extension can't reach the app's log).
        UserDefaults(suiteName: SharedNowPlaying.appGroupID)?
            .set(Date.now.timeIntervalSince1970, forKey: "laRefreshTappedAt")
        return .result()
    }
}

/// A small user-initiated refresh action for Home Screen widgets. WidgetKit
/// may delay ordinary timeline reloads after a track change; this action
/// foregrounds OpenLyrics and starts an immediate Spotify poll instead of
/// waiting for the next system refresh.
struct RefreshLyricsWidgetButton: View {
    var tint: Color = .secondary

    var body: some View {
        Button(intent: RefreshLyricsActivityIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Refresh lyrics")
        .accessibilityHint("Opens OpenLyrics and refreshes the current song.")
    }
}
