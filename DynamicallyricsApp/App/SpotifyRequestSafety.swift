import Foundation
import LyricCore

/// One process-wide request gate for each Spotify traffic class. Web API and
/// OAuth limits are intentionally separate because Spotify can throttle them
/// independently. Every phone Spotify request must enter through one of these
/// instances before touching URLSession.
@MainActor
final class SpotifyRequestGate {
    static let webAPI = SpotifyRequestGate(
        component: "phone-web-api",
        defaultsKey: "spotify_web_api_cooldown_until",
        legacyDefaultsKey: "spotify_rate_limit_until",
        rollingLimit: 20
    )
    static let oauth = SpotifyRequestGate(
        component: "phone-oauth",
        defaultsKey: "spotify_oauth_cooldown_until",
        rollingLimit: 8
    )

    private let component: String
    private let defaultsKey: String
    private let rollingLimit: Int
    private var requestWindow = SpotifyRequestWindow()
    private(set) var cooldownUntil: Date?

    private init(
        component: String,
        defaultsKey: String,
        legacyDefaultsKey: String? = nil,
        rollingLimit: Int
    ) {
        self.component = component
        self.defaultsKey = defaultsKey
        self.rollingLimit = rollingLimit
        let defaults = UserDefaults.standard
        cooldownUntil = defaults.object(forKey: defaultsKey) as? Date
            ?? legacyDefaultsKey.flatMap { defaults.object(forKey: $0) as? Date }
        if let cooldownUntil {
            defaults.set(cooldownUntil, forKey: defaultsKey)
        }
        if let legacyDefaultsKey {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }

    var isCoolingDown: Bool {
        remainingCooldown() > 0
    }

    @discardableResult
    func beginRequest(purpose: String, endpoint: String, now: Date = .now) -> Bool {
        if remainingCooldown(now: now) > 0 {
            logBlocked(purpose: purpose, endpoint: endpoint, reason: "cooldown")
            return false
        }

        let decision = requestWindow.begin(
            purpose: purpose,
            now: now,
            limit: rollingLimit
        )
        let counts = Self.countDescription(decision.countsByPurpose)
        DiagnosticsLog.append(
            "spotify-request component=\(component) purpose=\(purpose) endpoint=\(endpoint) " +
            "rolling30=\(decision.total) breakdown=\(counts)"
        )
        guard decision.permitted else {
            if let deadline = decision.blockedUntil {
                extendCooldown(until: deadline)
            }
            logBlocked(purpose: purpose, endpoint: endpoint, reason: "local_rolling_budget")
            return false
        }
        return true
    }

    func recordResponse(
        data: Data,
        response: HTTPURLResponse,
        purpose: String,
        endpoint: String,
        now: Date = .now
    ) {
        let rawRetryAfter = response.value(forHTTPHeaderField: "Retry-After")
        let reason = SpotifyRateLimitPolicy.reason(responseBody: data)
        let classification = SpotifyRateLimitPolicy.classification(
            status: response.statusCode,
            reason: reason
        )
        if response.statusCode == 429 {
            let delay = SpotifyRateLimitPolicy.delay(retryAfter: rawRetryAfter, now: now)
            extendCooldown(until: now.addingTimeInterval(delay))
        }
        let body = response.statusCode >= 400
            ? DiagnosticsLog.boundedResponseBody(data)
            : "[omitted-success]"
        DiagnosticsLog.append(
            "spotify-response component=\(component) purpose=\(purpose) endpoint=\(endpoint) " +
            "status=\(response.statusCode) retryAfter=\(rawRetryAfter ?? "-") " +
            "body=\(body) reason=\(reason ?? "-") classification=\(classification) " +
            "cooldownUntil=\(Self.iso8601(cooldownUntil))"
        )
    }

    func recordTransportFailure(error: Error, purpose: String, endpoint: String) {
        DiagnosticsLog.append(
            "spotify-response component=\(component) purpose=\(purpose) endpoint=\(endpoint) " +
            "status=transport_error retryAfter=- body=- reason=- classification=not_rate_limited " +
            "cooldownUntil=\(Self.iso8601(cooldownUntil)) error=\(error.localizedDescription)"
        )
    }

    /// A server cooldown returned by heartbeat is allowed to extend the local
    /// deadline but can never shorten a deadline already learned by the phone.
    func adopt(cooldown deadline: Date?) {
        guard let deadline, deadline > .now else { return }
        extendCooldown(until: deadline)
    }

    func remainingCooldown(now: Date = .now) -> TimeInterval {
        let remaining = SpotifyRateLimitPolicy.remaining(until: cooldownUntil, now: now)
        if remaining == 0, cooldownUntil != nil {
            cooldownUntil = nil
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return remaining
    }

    private func extendCooldown(until deadline: Date) {
        guard deadline > (cooldownUntil ?? .distantPast) else { return }
        cooldownUntil = deadline
        UserDefaults.standard.set(deadline, forKey: defaultsKey)
    }

    private func logBlocked(purpose: String, endpoint: String, reason: String) {
        DiagnosticsLog.append(
            "spotify-request-blocked component=\(component) purpose=\(purpose) endpoint=\(endpoint) " +
            "reason=\(reason) cooldownUntil=\(Self.iso8601(cooldownUntil))"
        )
    }

    private static func countDescription(_ counts: [String: Int]) -> String {
        counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: "|")
    }

    private static func iso8601(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
    }
}

enum SpotifyRequestGateError: LocalizedError {
    case cooldown(Date?)

    var errorDescription: String? {
        switch self {
        case .cooldown(let deadline):
            let value = deadline.map { ISO8601DateFormatter().string(from: $0) } ?? "later"
            return "Spotify requests are cooling down until \(value)."
        }
    }
}
