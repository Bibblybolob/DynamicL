import Foundation

/// A remote-control command sent from the widget extension to the main app.
public enum PlaybackCommand: String, Codable, Sendable, Equatable {
    case togglePlayPause
    /// User tapped the stall-reveal refresh button on the Live Activity.
    case refresh
}

/// Tiny mailbox in the shared app-group UserDefaults: the widget's App Intent
/// drops a command in, the app's tick loop picks it up and talks to Spotify.
public enum PlaybackCommandBus {
    private static let storageKey = "pendingPlaybackCommand"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedNowPlaying.appGroupID)
    }

    /// Called from the widget extension / Live Activity button.
    public static func send(_ command: PlaybackCommand) {
        send(command, defaults: sharedDefaults)
    }

    /// Reads and clears the pending command, if any.
    public static func consume() -> PlaybackCommand? {
        consume(defaults: sharedDefaults)
    }

    static func send(_ command: PlaybackCommand, defaults: UserDefaults?) {
        defaults?.set(command.rawValue, forKey: storageKey)
    }

    static func consume(defaults: UserDefaults?) -> PlaybackCommand? {
        guard let raw = defaults?.string(forKey: storageKey),
              let command = PlaybackCommand(rawValue: raw) else { return nil }
        defaults?.removeObject(forKey: storageKey)
        return command
    }
}
