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

    public static func shouldRestartFromWatchdog(
        isPolling: Bool,
        loopIsAlive: Bool,
        pollingAge: TimeInterval?,
        lastSuccessfulPollAge: TimeInterval?,
        maximumSilence: TimeInterval = 20
    ) -> Bool {
        guard isPolling, loopIsAlive else { return true }
        guard maximumSilence.isFinite, maximumSilence > 0 else { return false }
        if let lastSuccessfulPollAge {
            return !lastSuccessfulPollAge.isFinite
                || lastSuccessfulPollAge < 0
                || lastSuccessfulPollAge > maximumSilence
        }
        guard let pollingAge else { return false }
        return !pollingAge.isFinite
            || pollingAge < 0
            || pollingAge > maximumSilence
    }
}
