import Foundation
import LyricCore

/// Polls Spotify's `/v1/me/player` and publishes the latest track + playback status.
@MainActor
@Observable
final class SpotifyProvider {
    private(set) var signature: TrackSignature?
    private(set) var status: PlaybackStatus?
    private(set) var lastError: String?
    private(set) var lastPollSummary: String?
    private(set) var isPolling = false

    private let auth: SpotifyAuthManager
    private var pollTask: Task<Void, Never>?

    init(auth: SpotifyAuthManager) {
        self.auth = auth
    }

    func start() {
        // Idempotent (re)start: cancelling a dead/hung scheduler and rebuilding
        // is always safe; the watchdog relies on being able to call this freely.
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollCycle()
                // Stalled/rapid states poll fast to catch the transition ASAP.
                let fast = self?.usesRapidProbe == true || self?.isStalledPause == true
                try? await Task.sleep(for: .seconds(fast ? 0.7 : 3.0))
            }
        }
    }

    /// One full poll wrapped in a hard timeout. A hung URLSession request can
    /// never stall the scheduling loop — the group cancels it after 12s and
    /// the loop moves on regardless of the outcome.
    private func pollCycle() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.poll() }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private(set) var usesRapidProbe = false
    private var rapidProbesLeft = 0
    private var lastAppliedItemName: String?
    /// Last raw position Spotify reported, for frozen/backwards lie detection.
    private var lastAppliedPositionMs: Int?
    /// Timestamp of the last successful (HTTP 200) player-state fetch.
    private(set) var lastSuccessfulPollAt: Date?

    /// Schedules N fast polls so a user-initiated change (transport command,
    /// audio interruption) shows up in ≤N×0.7s instead of waiting out the 3s cadence.
    func burst(count: Int = 6) {
        rapidProbesLeft = max(rapidProbesLeft, count)
        usesRapidProbe = true
    }

    // MARK: Stalled stale-API pause detection
    // Spotify sometimes serves the old track as "paused" at a frozen position
    // for many seconds after a skip. If we treat that as a real pause the card
    // freezes; N consecutive identical frozen positions = API is lying.
    private var stalledPauseCount = 0
    private var lastFrozenPos: Int?
    private var didLogStall = false
    /// When the current stall episode was first confirmed (nil = none).
    private(set) var stalledSince: Date?
    /// True while we believe the API is serving a stale paused state.
    private(set) var isStalledPause = false
    static let stallThreshold = 4
    /// How long a confirmed stall keeps us in "act like playing" mode before we
    /// concede it might be a real pause (skip stale windows run 10–30s).
    static let stallKeepAliveGrace: TimeInterval = 60

    /// While a stall episode is confirmed the player really IS still playing —
    /// only Spotify's API went stale — so the background keep-alive must not be
    /// torn down the way it is for a genuine pause.
    var shouldHoldKeepAlive: Bool {
        guard isStalledPause, let since = stalledSince else { return false }
        return Date.now.timeIntervalSince(since) < Self.stallKeepAliveGrace
    }

    private func beginRapidProbe(staleItem: String?) {
        guard rapidProbesLeft == 0 else { return }
        rapidProbesLeft = 25
        usesRapidProbe = true
        DiagnosticsLog.append("rapid probe: api reports paused \(staleItem ?? "?") after playing")
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
                let state = try JSONDecoder().decode(SpotifyPlayerState.self, from: data)
                // Stall detector: frozen position across consecutive "paused"
                // polls = stale API, not a real pause.
                if !state.isPlaying, state.progressMs == lastFrozenPos {
                    stalledPauseCount += 1
                } else {
                    stalledPauseCount = 0
                    didLogStall = false
                }
                lastFrozenPos = state.progressMs
                isStalledPause = stalledPauseCount >= Self.stallThreshold
                if isStalledPause {
                    if stalledSince == nil { stalledSince = .now }
                } else {
                    stalledSince = nil
                }
                if isStalledPause, !didLogStall {
                    didLogStall = true
                    DiagnosticsLog.append("stall confirmed: \(stalledPauseCount) frozen polls at pos=\(lastFrozenPos ?? -1)")
                }

                apply(state)
                lastSuccessfulPollAt = .now
                lastPollSummary = state.device?.name.map { "playing on \($0)" } ?? "no device info"
                DiagnosticsLog.append("poll: item=\(state.item?.name ?? "nil") playing=\(state.isPlaying) pos=\(state.progressMs ?? -1)")
                lastError = nil
                if rapidProbesLeft > 0 {
                    rapidProbesLeft -= 1
                    if rapidProbesLeft == 0 { usesRapidProbe = false }
                }
            case 204:
                status = PlaybackStatus(state: .stopped, position: 0)
                lastPollSummary = "no active Spotify device (204)"
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
        // Fresh playing state ends any stall episode immediately.
        if state.isPlaying {
            stalledPauseCount = 0
            isStalledPause = false
            didLogStall = false
        }
        let wasPlaying = status?.state == .playing
        let itemName = state.item?.name
        // Old track flips to "paused" right after it was playing → classic
        // stale-API skip transition; probe fast until real state arrives.
        if wasPlaying, state.isPlaying == false, let itemName, itemName == lastAppliedItemName {
            beginRapidProbe(staleItem: itemName)
        }
        defer {
            lastAppliedItemName = itemName
            lastAlbumImageURL = state.albumImageURL
            signature = state.signature ?? signature
        }

        // Position-lie guard: while playing on the SAME track, a frozen or
        // slightly-backwards position is a stale seek/scrub echo, not truth —
        // never let the displayed position regress because of it.
        let newPos = state.progressMs
        if state.isPlaying, itemName == lastAppliedItemName,
           let newPos, let last = lastAppliedPositionMs,
           newPos <= last, abs(newPos - last) < 1500 {
            staleSeekCount += 1
            if staleSeekCount >= 3 {
                if suppressedLieSamples < 40 {
                    suppressedLieSamples += 1
                    return // keep projecting our current (advancing) status
                }
                // Concede after ~2min of continuous lies: show API truth
                // rather than diverge forever.
                DiagnosticsLog.append("position lies conceded after \(suppressedLieSamples) samples")
                staleSeekCount = 0
                suppressedLieSamples = 0
            }
        } else {
            staleSeekCount = 0
            suppressedLieSamples = 0
        }
        lastAppliedPositionMs = newPos ?? lastAppliedPositionMs
        status = state.status
    }

    @ObservationIgnored private var staleSeekCount = 0
    @ObservationIgnored private var suppressedLieSamples = 0

    /// Album cover URL from the most recent poll (for the vinyl widget etc).
    private(set) var lastAlbumImageURL: String?

    // MARK: Transport commands (remote command center / widget buttons)

    /// Seeks Spotify playback to the given position. Returns true when the
    /// request was accepted (204).
    @discardableResult
    func seek(to position: TimeInterval) async -> Bool {
        await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/seek?position_ms=\(Int(position * 1000))")!)
    }

    /// Skips to the next track.
    @discardableResult
    func next() async -> Bool {
        await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/next")!, method: "POST")
    }

    /// Skips back to the previous track.
    @discardableResult
    func previous() async -> Bool {
        await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/previous")!, method: "POST")
    }

    private func transportCall(url: URL, method: String = "PUT") async -> Bool {
        guard let token = try? await auth.validAccessToken() else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200...299).contains(http.statusCode) {
                burst()
                return true
            }
            return false
        } catch {
            return false
        }
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
