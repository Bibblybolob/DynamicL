import Foundation

/// Sends a direct lyric-boundary update only when the timestamped schedule
/// cannot advance the Live Activity on its own. Re-sending each scheduled
/// line consumes ActivityKit's update budget and can make later background
/// updates appear frozen.
public enum LiveActivityUpdatePolicy {
    private static let loadingMessages: Set<String> = [
        "Finding lyrics…",
        "Finding lyrics...",
        "Waiting for Spotify playback…",
        "Waiting for Spotify playback...",
        "Connecting to Spotify…",
        "Connecting to Spotify...",
    ]

    /// Identifies temporary text that must be replaced when a lyric document
    /// becomes available. Keep this shared between acknowledgement and retry
    /// logic so punctuation variants cannot strand a loading card.
    public static func isLoadingPlaceholder(_ line: String) -> Bool {
        loadingMessages.contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Allows the completed lyric state to be sent immediately and retried at
    /// 2, 4, and 8 seconds when ActivityKit still reports the placeholder.
    /// The bounded backoff repairs a dropped update without creating an
    /// update storm that would make system throttling worse.
    public static func shouldRetryLoadingPlaceholder(
        isPlaceholderApplied: Bool,
        attempts: Int,
        timeSinceLastAttempt: TimeInterval
    ) -> Bool {
        guard isPlaceholderApplied,
              attempts >= 0,
              attempts < 4,
              timeSinceLastAttempt.isFinite else {
            return false
        }
        if attempts == 0 { return true }
        let delays: [TimeInterval] = [2, 4, 8]
        return timeSinceLastAttempt >= delays[attempts - 1]
    }

    public static func shouldSendLineChange(
        lineChanged: Bool,
        hasUsableSchedule: Bool,
        timeSinceLastSend: TimeInterval,
        sendsInLastMinute: Int,
        minimumInterval: TimeInterval = 0.35,
        maximumSendsPerMinute: Int = 12,
        throttledRecoveryInterval: TimeInterval = 5
    ) -> Bool {
        guard lineChanged,
              !hasUsableSchedule,
              timeSinceLastSend.isFinite,
              timeSinceLastSend >= minimumInterval,
              sendsInLastMinute >= 0 else {
            return false
        }
        if sendsInLastMinute < maximumSendsPerMinute {
            return true
        }
        // Do not enter a hard freeze after a lyric-heavy minute. Slow direct
        // updates while the timestamp schedule remains the primary path.
        return timeSinceLastSend >= throttledRecoveryInterval
    }
}
