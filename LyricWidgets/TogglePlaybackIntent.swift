import AppIntents
import ActivityKit
import SwiftUI
import LyricCore

/// Play/pause toggle run inside the widget extension when the user taps the
/// button on a home-screen widget or the Lock Screen Live Activity.
struct ToggleLyricPlaybackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggles playback of the song shown in the OpenLyrics widget.")
    /// Run the mailbox handoff in the app process without opening its UI on
    /// current systems. The app owns the Spotify call; the extension only
    /// records the command.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background]
    /// Keep the pre-iOS 26 behavior for devices that do not know
    /// `supportedModes`.
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Optimistic UI flip first so widgets reload instantly…
        let snapshot = SharedNowPlaying.load()
        if let snapshot {
            // Ignore an older track's short-lived override. A rapid skip can
            // leave that mailbox value present for a few seconds, but it must
            // not change the meaning of this tap for the current song.
            let current = SharedNowPlaying.effectiveIsPlaying(snapshot)
            SharedNowPlaying.setPlayingOverride(!current, trackID: snapshot.trackID)
        }

        // A transport tap must not silently enable the high-power phone
        // session. The dedicated Show Lyrics action is the explicit first-use
        // handoff. This command only asks the app to control Spotify.
        PlaybackCommandBus.send(.togglePlayPause)

        return .result()
    }
}

/// Opens OpenLyrics and changes a placeholder Live Activity into the active
/// phone-owned lyric session. Dynamic Lyrics uses the same explicit first-use
/// action so iOS gives the app a foreground execution window before it must
/// keep updating a locked-screen activity. This starts the lyric session but
/// does not silently enable the optional battery-heavy background mode.
struct StartLyricsSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Lyrics"
    static let description = IntentDescription(
        "Starts the OpenLyrics session for the current Spotify song."
    )
    /// On iOS 26 and later, run the handoff after the app is brought to the
    /// foreground. This gives AppModel a real execution window to consume the
    /// one-shot request and load the lyric schedule before the device locks
    /// again. Keep the legacy flag for iOS 17–25.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Bind the handoff to the Activity whose Show Lyrics button was
        // pressed. A delayed app launch must not activate a newer Activity.
        let activeActivities = Activity<LyricsActivityAttributes>.activities.filter {
            $0.activityState != .ended && $0.activityState != .dismissed
        }
        // Prefer the gated card. This matters during a short relaunch race
        // when an older completed Activity and the new first-use card can both
        // still be visible to ActivityKit.
        let activityID = activeActivities.first(
            where: { $0.content.state.requiresUserStart == true }
        )?.id ?? activeActivities.first?.id
        SharedNowPlaying.requestLocalSessionStart(activityID: activityID)
        // Keep this LiveActivityIntent alive briefly while iOS brings the app
        // process forward. The app consumes the request, starts its Spotify
        // poller, and takes ownership before the user can lock the screen
        // again. The request itself starts the immediate poll burst; queuing a
        // second generic refresh here would restart that poller and delay the
        // first accepted Spotify sample.
        try? await Task.sleep(for: .seconds(3))
        return .result()
    }
}

/// On iOS 18 and later, this is the Control Center quick switch for the
/// phone-owned lyric session. The app consumes the request so the same state
/// change can end a Live Activity as well as start one.
@available(iOS 18.0, *)
struct LiveActivityControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Live Activity Lyrics"
    static let description = IntentDescription(
        "Shows or hides lyrics on the Lock Screen and Dynamic Island."
    )
    /// A control request must wake the app immediately so it can consume the
    /// shared request and start the phone-owned session. This is the direct
    /// start path that avoids the extra Show Lyrics tap.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @available(iOS, introduced: 18.0, obsoleted: 26.0)
    static let openAppWhenRun = true

    @Parameter(title: "Enabled")
    var value: Bool

    init() {
        value = false
    }

    init(value: Bool) {
        self.value = value
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedNowPlaying.requestLiveActivityControl(value)
        if value {
            SharedNowPlaying.requestLocalSessionStart()
            // A Control Center tap can launch OpenLyrics from a terminated
            // state. Keep the intent alive briefly so the app can consume the
            // request, start the Spotify poller, and take ownership before
            // the control reports success. This is the same handoff used by
            // the Live Activity's Show Lyrics action.
            try? await Task.sleep(for: .seconds(3))
        }
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
struct NextTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Next Track"
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background]
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCommandBus.send(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Previous Track"
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background]
    @available(iOS, introduced: 17.0, obsoleted: 26.0)
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
