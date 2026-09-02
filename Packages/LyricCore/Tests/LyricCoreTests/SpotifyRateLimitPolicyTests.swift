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
        #expect(SpotifyRateLimitPolicy.delay(retryAfter: "999999") == 86_400)
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
