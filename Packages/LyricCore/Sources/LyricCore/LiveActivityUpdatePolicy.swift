import Foundation

/// Sends a direct lyric-boundary update only when the timestamped schedule
/// cannot advance the Live Activity on its own. Re-sending each scheduled
/// line consumes ActivityKit's update budget and can make later background
/// updates appear frozen.
public enum LiveActivityUpdatePolicy {
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
