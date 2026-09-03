import Foundation

/// Decides when automatic Spotify detection can confirm a Live Activity start.
/// The app owns the haptic; this policy keeps it one-shot per playback session.
public enum AutomaticActivityFeedbackPolicy {
    public static func shouldQueue(
        previousState: PlaybackStatus.State?,
        currentState: PlaybackStatus.State?,
        isArmed: Bool,
        automaticLyricsEnabled: Bool,
        appIsActive: Bool
    ) -> Bool {
        isArmed
            && automaticLyricsEnabled
            && appIsActive
            && previousState != .playing
            && currentState == .playing
    }

    public static func shouldRearm(currentState: PlaybackStatus.State?) -> Bool {
        currentState == .stopped
    }

    public static func shouldDeliver(
        isPending: Bool,
        activityIsRunning: Bool,
        appIsActive: Bool
    ) -> Bool {
        isPending && activityIsRunning && appIsActive
    }
}
