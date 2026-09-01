import Foundation

/// Limits direct lyric-boundary updates without disabling them when a future
/// schedule is present. The schedule remains a fallback for app suspension.
public enum LiveActivityUpdatePolicy {
    public static func shouldSendLineChange(
        lineChanged: Bool,
        timeSinceLastSend: TimeInterval,
        sendsInLastMinute: Int,
        minimumInterval: TimeInterval = 0.5,
        maximumSendsPerMinute: Int = 20
    ) -> Bool {
        guard lineChanged,
              timeSinceLastSend.isFinite,
              timeSinceLastSend >= minimumInterval,
              sendsInLastMinute >= 0,
              sendsInLastMinute < maximumSendsPerMinute else {
            return false
        }
        return true
    }
}
