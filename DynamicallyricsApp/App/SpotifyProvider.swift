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
        // Heartbeat for liveness checks: a fresh stamp at each iteration start.
        lastLoopActivityAt = .now
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.poll() }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// When the polling loop last showed life. Requests are capped at 12s and
    /// backoffs at 15s, so a heartbeat older than this means the loop is
    /// genuinely dead or hung — not merely waiting on a slow request.
    private(set) var lastLoopActivityAt: Date?
    static let loopStaleThreshold: TimeInterval = 20

    var isLoopLikelyAlive: Bool {
        guard let last = lastLoopActivityAt else { return false }
        return Date.now.timeIntervalSince(last) < Self.loopStaleThreshold
    }

    /// Immediate poll: restarts the scheduling loop so the next request fires
    /// now instead of after the current inter-poll sleep. Safe to call freely.
    func kick() {
        start()
    }

    private(set) var usesRapidProbe = false
    private var rapidProbesLeft = 0
    private var lastAppliedItemKey: String?
    /// Last raw position Spotify reported, for frozen/backwards lie detection.
    private var lastAppliedPositionMs: Int?
    /// Timestamp of the last successful (HTTP 200) player-state fetch.
    private(set) var lastSuccessfulPollAt: Date?

    // MARK: Post-skip stale-echo rejection
    // After a commanded skip, /v1/me/player keeps serving the PREVIOUS track
    // as still-playing with an advancing position for 10–30s. Trusting it
    // makes the LA count up the dead song. For a short window after every
    // successful skip command, polls echoing the pre-skip item are discarded.
    //
    // KNOWN LIMIT — external skips (Spotify app / Spotify's lock-screen
    // player, which owns transport while it holds audible playback; our
    // remote-command bridge never fires in that case): a stale echo of the
    // old track PLAYING is indistinguishable from continued playback until a
    // different item arrives, so it can't be rejected without risking real
    // pauses/scrubs. The stall probe + LA reconciliation self-heal cover the
    // common paused-echo variant and any resulting render freeze.
    private var pendingSkipItemKey: String?
    private var pendingSkipDeadline: Date?
    static let skipEchoWindow: TimeInterval = 25

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
                // Transition in progress (stale pause-echo or post-command
                // probes): /me/player may be serving stale slices of the dead
                // track. Cross-check against recently-played, which reports
                // what actually played and flips us onto the real track fast.
                await maybeCrossCheckRecentlyPlayed()
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
                // Capped: a long server-side nap must never deafen the loop to
                // kicks/bursts — 15s still respects the server's signal.
                try? await Task.sleep(for: .seconds(min(retryAfter, 15)))
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
        // Post-skip echo rejection runs before anything else: a poll that
        // still shows the pre-skip track carries zero information, so don't
        // let it touch stall bookkeeping, the lie guard, or status/signature.
        if let pending = pendingSkipItemKey {
            let expired = Date.now >= (pendingSkipDeadline ?? .distantPast)
            // Repeat-one: same item, playing, restarted near 0 — real truth.
            let restart = state.isPlaying && (state.progressMs ?? 999_999) < 5_000
            if expired || itemKey(for: state.item) != pending || restart {
                pendingSkipItemKey = nil
                DiagnosticsLog.append("skip resolved: \(state.item?.name ?? "?")")
            } else {
                rapidProbesLeft = max(rapidProbesLeft, 3)
                DiagnosticsLog.append("skip echo ignored: \(state.item?.name ?? "?") pos=\(state.progressMs ?? -1)")
                return
            }
        }

        // Fresh playing state ends any stall episode immediately.
        if state.isPlaying {
            stalledPauseCount = 0
            isStalledPause = false
            didLogStall = false
        }
        let wasPlaying = status?.state == .playing
        let itemName = state.item?.name
        let identityKey = itemKey(for: state.item)
        // Old track flips to "paused" right after it was playing → classic
        // stale-API skip transition; probe fast until real state arrives.
        if wasPlaying, state.isPlaying == false, let identityKey, identityKey == lastAppliedItemKey {
            beginRapidProbe(staleItem: itemName)
        }
        defer {
            lastAppliedItemKey = identityKey
            lastAlbumImageURL = state.albumImageURL
            signature = state.signature
        }

        // Position-lie guard: while playing on the SAME track, a frozen or
        // slightly-backwards position is a stale seek/scrub echo, not truth —
        // never let the displayed position regress because of it.
        let newPos = state.progressMs
        if state.isPlaying, identityKey == lastAppliedItemKey,
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
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/next")!, method: "POST")
        if ok { armPendingSkip() }
        return ok
    }

    /// Skips back to the previous track.
    @discardableResult
    func previous() async -> Bool {
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/previous")!, method: "POST")
        if ok { armPendingSkip() }
        return ok
    }

    /// Arms stale-echo rejection for a fresh skip: freeze the displayed
    /// position immediately (the LA flips to its static bar via the urgent
    /// play-change path) and discard polls still echoing the pre-skip track.
    private func armPendingSkip() {
        guard let preSkip = lastAppliedItemKey else { return }
        pendingSkipItemKey = preSkip
        pendingSkipDeadline = .now.addingTimeInterval(Self.skipEchoWindow)
        burst(count: 10)
        if let status, status.state == .playing {
            self.status = PlaybackStatus(state: .paused, position: status.position(at: .now))
        }
        DiagnosticsLog.append("skip armed: freezing over \(preSkip)")
    }

    // MARK: Recently-played cross-check
    // While locked, /v1/me/player replays stale slices of a skipped track for
    // 10–30s — even flipping back to "playing" with advancing (or rewound)
    // positions. That endpoint can't be trusted mid-transition, but
    // /recently-played reports what ACTUALLY played with played_at stamps.
    // During any active transition we poll it cheaply; a fresh entry for a
    // different track flips us onto the real song immediately instead of
    // counting up the dead one until /me/player catches up.
    private var lastRecentlyPlayedCheckAt: Date?

    private func maybeCrossCheckRecentlyPlayed() async {
        guard isStalledPause || rapidProbesLeft > 0 else { return }
        if let last = lastRecentlyPlayedCheckAt,
           Date.now.timeIntervalSince(last) < 2.5 { return }
        lastRecentlyPlayedCheckAt = .now

        guard let token = try? await auth.validAccessToken() else { return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=5")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RecentlyPlayedResponse.self, from: data),
              let newest = decoded.items.first else { return }

        guard let name = newest.track?.name else { return }
        let recentlyPlayedKey = itemKey(
            id: newest.track?.id,
            name: name,
            artist: newest.track?.artists?.first?.name ?? "",
            album: newest.track?.album?.name
        )
        guard recentlyPlayedKey != lastAppliedItemKey else { return } // no skip happened
        // Only fresh plays count as skips; older history entries are noise.
        guard let playedAt = newest.playedAt,
              Date.now.timeIntervalSince(playedAt) < 60 else {
            DiagnosticsLog.append("recently-played: \(name) too old to trust")
            return
        }
        applyOptimisticFlip(entry: newest)
    }

    /// Switches onto the track recently-played proves is actually playing,
    /// with position estimated from its played_at stamp. The abandoned track
    /// gets echo armor so later stale slices of it are discarded.
    private func applyOptimisticFlip(entry: RecentlyPlayedResponse.Item) {
        guard let track = entry.track, let name = track.name else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(entry.playedAt ?? .now))
        let duration = track.durationMs.map { TimeInterval($0) / 1000.0 }
        if let dying = lastAppliedItemKey {
            pendingSkipItemKey = dying
            pendingSkipDeadline = .now.addingTimeInterval(Self.skipEchoWindow)
        }
        signature = TrackSignature(
            title: name,
            artist: track.artists?.first?.name ?? "",
            album: track.album?.name,
            duration: duration
        )
        status = PlaybackStatus(
            state: .playing,
            position: min(elapsed, duration ?? elapsed),
            rate: 1.0
        )
        lastAlbumImageURL = track.album?.images?
            .last(where: { ($0.width ?? 0) >= 300 })?.url
            ?? track.album?.images?.last?.url
        lastAppliedItemKey = itemKey(
            id: track.id,
            name: name,
            artist: track.artists?.first?.name ?? "",
            album: track.album?.name
        )
        lastAppliedPositionMs = Int(min(elapsed, duration ?? elapsed) * 1000)
        stalledPauseCount = 0
        isStalledPause = false
        didLogStall = false
        stalledSince = nil
        burst(count: 8)
        DiagnosticsLog.append("recently-played flip: \(name) est=\(Int(elapsed))s")
    }

    private func itemKey(for item: SpotifyPlayerState.Item?) -> String? {
        guard let item else { return nil }
        return itemKey(
            id: item.id,
            name: item.name,
            artist: item.artists?.first?.name ?? "",
            album: item.album?.name
        )
    }

    private func itemKey(id: String?, name: String, artist: String, album: String?) -> String {
        id ?? "\(name)|\(artist)|\(album ?? "")"
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

/// Subset of `GET /v1/me/player/recently-played`.
private struct RecentlyPlayedResponse: Codable, Sendable {
    struct Item: Codable, Sendable {
        struct Playable: Codable, Sendable {
            var id: String?
            var name: String?
            var durationMs: Int?
            var artists: [Artist]?
            var album: Album?

            struct Artist: Codable, Sendable { var name: String }
            struct Album: Codable, Sendable {
                var name: String?
                var images: [Image]?
                struct Image: Codable, Sendable {
                    var url: String?
                    var width: Int?
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, artists, album
                case durationMs = "duration_ms"
            }
        }

        var track: Playable?
        private var playedAtRaw: String?

        enum CodingKeys: String, CodingKey {
            case track
            case playedAtRaw = "played_at"
        }

        /// Spotify stamps plays with fractional-second UTC ISO8601; tolerate
        /// both formats so a server-side format change can't break decoding.
        var playedAt: Date? {
            guard let raw = playedAtRaw else { return nil }
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            return try? Date(raw, strategy: .iso8601)
        }
    }

    var items: [Item]
}
