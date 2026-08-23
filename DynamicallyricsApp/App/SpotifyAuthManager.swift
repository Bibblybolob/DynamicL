import AuthenticationServices
import CryptoKit
import Foundation
import LyricCore
import Observation

@MainActor
@Observable
final class SpotifyAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var tokenExpiresAt: Date?

    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private var refreshTask: Task<String, Error>?

    var isConnected: Bool { accessToken != nil }

    override init() {
        super.init()
        accessToken = KeychainStore.string(forKey: "access_token")
        refreshToken = KeychainStore.string(forKey: "refresh_token")
        if let expiry = KeychainStore.string(forKey: "token_expiry") {
            tokenExpiresAt = ISO8601DateFormatter().date(from: expiry)
        }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        KeychainStore.removeAll()
    }

    func connect() async throws {
        let verifier = PKCE.generateVerifier()
        let state = PKCE.randomState()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: SpotifyConfig.clientID),
            .init(name: "scope", value: SpotifyConfig.scopes),
            .init(name: "redirect_uri", value: SpotifyConfig.redirectURI.absoluteString),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: PKCE.challenge(from: verifier)),
            .init(name: "state", value: state),
        ]

        let code = try await authorize(url: components.url!, expectedState: state)
        try await exchange(code: code, verifier: verifier)
    }

    /// Returns a valid access token, refreshing first when necessary.
    /// Concurrent callers share a single in-flight refresh instead of racing
    /// duplicate POSTs to /api/token against each other.
    func validAccessToken() async throws -> String {
        if let accessToken, let expiresAt = tokenExpiresAt, Date.now < expiresAt.addingTimeInterval(-30) {
            return accessToken
        }
        guard let refreshToken else {
            throw SpotifyAuthError.notAuthenticated
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw SpotifyAuthError.notAuthenticated }
            return try await self.refresh(using: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Drops the cached access token so the next validAccessToken() performs a real
    /// refresh. Use when the server rejects a token that still looks valid locally;
    /// keeps the refresh token intact so the refresh can actually happen.
    func invalidateAccessToken() {
        accessToken = nil
        tokenExpiresAt = nil
        KeychainStore.set(nil, forKey: "access_token")
        KeychainStore.set(nil, forKey: "token_expiry")
    }

    private func authorize(url: URL, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SpotifyConfig.redirectURI.scheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: SpotifyAuthError.webAuth(error.localizedDescription))
                    return
                }
                guard let url = callbackURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    continuation.resume(throwing: SpotifyAuthError.invalidCallback)
                    return
                }
                let queryItems = components.queryItems ?? []
                if let errorDescription = queryItems.first(where: { $0.name == "error" })?.value {
                    continuation.resume(throwing: SpotifyAuthError.webAuth(errorDescription))
                    return
                }
                guard queryItems.first(where: { $0.name == "state" })?.value == expectedState,
                      let code = queryItems.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: SpotifyAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            // When start() fails the completion handler is never called, so the
            // continuation must be resumed here or connect() hangs forever.
            if !session.start() {
                self.webSession = nil
                continuation.resume(throwing: SpotifyAuthError.webAuth("Could not start the Spotify sign-in flow."))
            }
        }
    }

    private func exchange(code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI.absoluteString,
            "client_id": SpotifyConfig.clientID,
            "code_verifier": verifier,
        ]
        request.httpBody = formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyAuthError.tokenExchange("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let tokens = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        store(tokens: tokens)
    }

    private func refresh(using refresh: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": SpotifyConfig.clientID,
        ]
        request.httpBody = formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAuthError.tokenExchange("invalid response")
        }
        guard http.statusCode == 200 else {
            // Only 400/401 mean the refresh token itself is dead and signing out is
            // warranted. Transient failures (429, 5xx) must not wipe stored tokens,
            // e.g. those just written by another concurrent caller.
            if http.statusCode == 400 || http.statusCode == 401 {
                disconnect()
            }
            throw SpotifyAuthError.tokenExchange("HTTP \(http.statusCode)")
        }
        let tokens = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        store(tokens: tokens, keepingRefreshToken: tokens.refreshToken == nil ? refreshToken : nil)
        return tokens.accessToken
    }

    private func store(tokens: SpotifyTokenResponse, keepingRefreshToken fallback: String? = nil) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken ?? fallback
        tokenExpiresAt = Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        KeychainStore.set(tokens.accessToken, forKey: "access_token")
        KeychainStore.set(refreshToken, forKey: "refresh_token")
        KeychainStore.set(tokenExpiresAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: "token_expiry")
    }

    private func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)!)"
        }
        .joined(separator: "&")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard Thread.isMainThread else { return ASPresentationAnchor() }
        return MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum SpotifyAuthError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidCallback
    case webAuth(String)
    case tokenExchange(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in to Spotify."
        case .invalidCallback: "Unexpected response from the Spotify sign-in flow."
        case .webAuth(let detail): "Spotify sign-in failed: \(detail)"
        case .tokenExchange(let detail): "Token exchange failed (\(detail)). Check your Client ID and redirect URI."
        }
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
