import Foundation
import LyricCore

/// Polls Spotify's `/v1/me/player` and publishes the latest track + playback status.
@MainActor
@Observable
final class SpotifyProvider {
    private(set) var signature: TrackSignature?
    private(set) var status: PlaybackStatus?
    private(set) var lastError: String?
    private(set) var isPolling = false

    private let auth: SpotifyAuthManager
    private var pollTask: Task<Void, Never>?

    init(auth: SpotifyAuthManager) {
        self.auth = auth
    }

    func start() {
        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func poll() async {
        do {
            let (data, http) = try await requestPlayerState()
            switch http.statusCode {
            case 200:
                apply(try JSONDecoder().decode(SpotifyPlayerState.self, from: data))
                lastError = nil
            case 204:
                status = PlaybackStatus(state: .stopped, position: 0)
                lastError = nil
            case 429:
                let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                try? await Task.sleep(for: .seconds(min(retryAfter, 60)))
            default:
                throw LyricsLookupError(kind: .network("HTTP \(http.statusCode)"))
            }
        } catch let error as SpotifyAuthError where error == .notAuthenticated {
            stop()
            lastError = error.errorDescription
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Performs the `/v1/me/player` request. On a 401 the locally cached token was
    /// rejected by the server, so force a real refresh and retry once.
    private func requestPlayerState() async throws -> (Data, HTTPURLResponse) {
        var token = try await auth.validAccessToken()
        var retried401 = false
        while true {
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LyricsLookupError(kind: .network("invalid response"))
            }
            guard http.statusCode == 401, !retried401 else {
                return (data, http)
            }
            retried401 = true
            auth.invalidateAccessToken()
            token = try await auth.validAccessToken()
        }
    }

    private func apply(_ state: SpotifyPlayerState) {
        signature = state.signature ?? signature
        status = state.status
    }

    /// Toggles play/pause via the Spotify Web API. Returns true when a request
    /// went out and got accepted (204); false when there was nothing to control.
    @discardableResult
    func togglePlayPause() async -> Bool {
        guard let token = try? await auth.validAccessToken() else { return false }

        let base = URL(string: "https://api.spotify.com/v1/me/player")!
        let target: URL
        if status?.state == .playing {
            target = base.appendingPathComponent("pause")
        } else {
            target = base.appendingPathComponent("play")
        }

        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401 || http.statusCode == 403 {
                lastError = "Playback control not permitted (HTTP \(http.statusCode)). Sign out and back in to grant the new permission."
                return false
            }
            return (200...299).contains(http.statusCode)
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
