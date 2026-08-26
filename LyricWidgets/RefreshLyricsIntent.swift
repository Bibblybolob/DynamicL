import AppIntents
import LyricCore

/// Runs when the user taps the ↻ button that appears on the Lock Screen
/// activity once its content goes stale. Routes through the shared mailbox
/// like the play/pause intent — the extension has no Spotify access of its
/// own, but the audio keep-alive holds the main app alive through exactly
/// the stalls this button exists for.
struct RefreshLyricsActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh"
    static let description = IntentDescription("Forces an immediate playback poll so lyrics catch up.")

    // The stall scenarios this button exists for are exactly the ones where
    // the main app may be dead — and a mailbox write can't wake a dead app.
    // Foregrounding the app guarantees the queued command gets consumed.
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Mailbox command for the app's tick loop…
        PlaybackCommandBus.send(.refresh)
        // …plus a receipt in the shared defaults so a silent failure on the
        // app side is diagnosable (the extension can't reach the app's log).
        UserDefaults(suiteName: SharedNowPlaying.appGroupID)?
            .set(Date.now.timeIntervalSince1970, forKey: "laRefreshTappedAt")
        return .result()
    }
}
