import Foundation

/// Limits direct lyric-boundary updates without disabling them when a future
/// schedule is present. The schedule remains a fallback for app suspension.
public enum LiveActivityUpdatePolicy {
    public static func shouldSendLineChange(
        lineChanged: Bool,
        timeSinceLastSend: TimeInterval,
        sendsInLastMinute: Int,
        minimumInterval: TimeInterval = 0.35,
        maximumSendsPerMinute: Int = 48,
        throttledRecoveryInterval: TimeInterval = 2
    ) -> Bool {
        guard lineChanged,
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
