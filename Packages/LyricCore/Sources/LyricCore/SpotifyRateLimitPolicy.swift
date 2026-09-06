import Foundation

/// Converts Spotify's `Retry-After` response into one shared delay.
/// A rate limit is a scheduling instruction, not a network failure to retry
/// immediately.
public enum SpotifyRateLimitPolicy {
    public static let defaultDelay: TimeInterval = 30

    public static func delay(
        retryAfter: String?,
        defaultDelay: TimeInterval = defaultDelay,
        now: Date = .now
    ) -> TimeInterval {
        let cleaned = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = cleaned.flatMap { TimeInterval($0) }
        let httpDate = cleaned.flatMap(parseHTTPDate)
        let requested = seconds.map { max(0, $0) }
            ?? httpDate.map { max(0, $0.timeIntervalSince(now)) }
            ?? defaultDelay
        // Spotify has issued valid multi-hour and multi-day waits in
        // development quota mode. Do not silently shorten its instruction.
        return max(1, requested)
    }

    public static func remaining(until: Date?, now: Date = .now) -> TimeInterval {
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    public static func reason(responseBody: Data) -> String? {
        guard !responseBody.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: responseBody) else {
            return nil
        }
        return reason(in: object)
    }

    public static func classification(status: Int, reason: String?) -> String {
        guard status == 429 else { return "not_rate_limited" }
        return reason?.uppercased() == "QUOTA_EXCEEDED"
            ? "quota_exceeded"
            : "rate_limit"
    }

    private static func reason(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let reason = dictionary["reason"] as? String {
                let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
            for nested in dictionary.values {
                if let reason = reason(in: nested) { return reason }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let reason = reason(in: nested) { return reason }
            }
        }
        return nil
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// A small rolling request ledger used by the phone's single Spotify Web API
/// gate. It limits timer and recovery traffic together instead of letting each
/// call site own an independent burst counter.
public struct SpotifyRequestWindow: Sendable {
    public struct Decision: Sendable, Equatable {
        public let permitted: Bool
        public let blockedUntil: Date?
        public let total: Int
        public let countsByPurpose: [String: Int]
    }

    private struct Entry: Sendable {
        let date: Date
        let purpose: String
    }

    private var entries: [Entry] = []

    public init() {}

    public mutating func begin(
        purpose: String,
        now: Date = .now,
        limit: Int = 20,
        interval: TimeInterval = 30
    ) -> Decision {
        entries.removeAll { now.timeIntervalSince($0.date) >= interval }
        guard entries.count < max(1, limit) else {
            let blockedUntil = entries.first?.date.addingTimeInterval(interval)
            return Decision(
                permitted: false,
                blockedUntil: blockedUntil,
                total: entries.count,
                countsByPurpose: counts
            )
        }
        entries.append(Entry(date: now, purpose: purpose))
        return Decision(
            permitted: true,
            blockedUntil: nil,
            total: entries.count,
            countsByPurpose: counts
        )
    }

    private var counts: [String: Int] {
        Dictionary(grouping: entries, by: \.purpose)
            .mapValues(\.count)
    }
}
