import Foundation
import Testing
@testable import LyricCore

struct SpotifyRateLimitPolicyTests {
    @Test
    func usesSpotifyRetryAfterSeconds() {
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "120") == 120)
    }

    @Test
    func usesSafeDefaultForMissingOrInvalidHeader() {
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: nil) == 30)
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "invalid") == 30)
    }

    @Test
    func boundsInvalidAndExtremeDelays() {
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "-5") == 1)
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "999999") == 999_999)
    }

    @Test
    func preservesMultiHourAndHTTPDateRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "18997", now: now) == 18_997)
        #expect(SpotifyRateLimitPolicy.delay(
            retryAfter: "Tue, 14 Nov 2023 23:13:20 GMT",
            now: now
        ) == 3_600)
    }

    @Test
    func classifiesQuotaExceededFromNestedSpotifyBody() throws {
        let data = try #require(#"{"error":{"status":429,"reason":"QUOTA_EXCEEDED"}}"#.data(using: .utf8))
        let reason = SpotifyRateLimitPolicy.reason(responseBody: data)
        #expect(reason == "QUOTA_EXCEEDED")
        #expect(SpotifyRateLimitPolicy.classification(status: 429, reason: reason) == "quota_exceeded")
        #expect(SpotifyRateLimitPolicy.classification(status: 429, reason: "rate limited") == "rate_limit")
    }

    @Test
    func rollingWindowBoundsRecoveryBursts() {
        var window = SpotifyRequestWindow()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<4 {
            let decision = window.begin(purpose: "recovery", now: start.addingTimeInterval(Double(index)), limit: 4)
            #expect(decision.permitted)
        }
        let blocked = window.begin(purpose: "command", now: start.addingTimeInterval(4), limit: 4)
        #expect(!blocked.permitted)
        #expect(blocked.blockedUntil == start.addingTimeInterval(30))
        #expect(blocked.countsByPurpose == ["recovery": 4])

        let recovered = window.begin(purpose: "command", now: start.addingTimeInterval(31), limit: 4)
        #expect(recovered.permitted)
    }

    @Test
    func reportsOnlyFutureRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(SpotifyRateLimitPolicy.remaining(
            until: now.addingTimeInterval(45),
            now: now
        ) == 45)
        #expect(SpotifyRateLimitPolicy.remaining(
            until: now.addingTimeInterval(-1),
            now: now
        ) == 0)
    }
}
