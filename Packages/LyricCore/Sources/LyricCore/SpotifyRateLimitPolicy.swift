import Foundation

/// Converts Spotify's `Retry-After` response into one shared, bounded delay.
/// A rate limit is a scheduling instruction, not a network failure to retry
/// immediately.
public enum SpotifyRateLimitPolicy {
    public static let defaultDelay: TimeInterval = 30
    public static let maximumDelay: TimeInterval = 24 * 60 * 60

    public static func delay(
        retryAfter: String?,
        defaultDelay: TimeInterval = defaultDelay,
        maximumDelay: TimeInterval = maximumDelay
    ) -> TimeInterval {
        let cleaned = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.flatMap { TimeInterval($0) }
        let requested = value.map { max(0, $0) } ?? defaultDelay
        return min(maximumDelay, max(1, requested))
    }

    public static func remaining(until: Date?, now: Date = .now) -> TimeInterval {
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }
}
