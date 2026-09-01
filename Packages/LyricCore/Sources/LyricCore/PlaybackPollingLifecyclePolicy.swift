import Foundation

/// Keeps Spotify polling stable across scene and background transitions.
public enum PlaybackPollingLifecyclePolicy {
    public static func shouldReuseLoop(
        isPolling: Bool,
        lastLoopActivityAge: TimeInterval?,
        staleAfter: TimeInterval
    ) -> Bool {
        guard isPolling, staleAfter.isFinite, staleAfter > 0 else { return false }
        // A newly created scheduler has not stamped its first cycle yet. It is
        // still the correct loop and must not be cancelled by a second start.
        guard let lastLoopActivityAge else { return true }
        return lastLoopActivityAge.isFinite
            && lastLoopActivityAge >= 0
            && lastLoopActivityAge < staleAfter
    }

    public static func shouldRunWatchdog(
        isConnected: Bool,
        isForeground: Bool,
        localSessionActive: Bool
    ) -> Bool {
        isConnected && (isForeground || localSessionActive)
    }
}
