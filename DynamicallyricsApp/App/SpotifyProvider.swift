import Foundation
import LyricCore

/// Polls Spotify's playback endpoints and publishes the latest track + playback status.
@MainActor
@Observable
final class SpotifyProvider: PlaybackProvider {
    private(set) var signature: TrackSignature?
    private(set) var status: PlaybackStatus?
    private(set) var lastError: String?
    private(set) var lastPollSummary: String?
    private(set) var isPolling = false

    private let auth: SpotifyAuthManager
    private var pollTask: Task<Void, Never>?
    /// Only the inter-poll delay is cancellable. A transport event sets one
    /// pending wake bit, so repeated events cannot create parallel requests or
    /// turn the scheduler into a tight loop.
    private var pollDelayTask: Task<Void, Never>?
    private var pollWakePending = false
    /// A dedicated session prevents an old hung Spotify connection from
    /// poisoning unrelated app traffic. The timeout path replaces this
    /// session before the next request.
    private var playerSession = SpotifyProvider.makePlayerSession()
    /// Every scheduler restart owns a new generation. A request from a
    /// cancelled scheduler can still finish at the URLSession boundary; this
    /// value prevents that old response from overwriting a newer track,
    /// position, or play state.
    private var pollGeneration: UInt64 = 0
    private var metadata = NowPlayingMetadata()
    /// Canonical playback reducer shared with the server and fixture tests.
    /// Transport-specific stale-echo checks run first; accepted samples then
    /// update this reducer for stable identity, metadata merging, and seek
    /// classification.
    private var unifiedPlayback = PlaybackStateReducer()
    private(set) var canonicalPlaybackRevision: Int64 = 0

    init(auth: SpotifyAuthManager) {
        self.auth = auth
    }

    func start() {
        let loopAge = lastLoopActivityAt.map { Date.now.timeIntervalSince($0) }
        if PlaybackPollingLifecyclePolicy.shouldReuseLoop(
            isPolling: isPolling,
            lastLoopActivityAge: loopAge,
            staleAfter: Self.loopStaleThreshold
        ) {
            // App activation and SwiftUI onAppear can request polling during
            // the same launch. Wake the existing scheduler instead of
            // cancelling its first Spotify request and leaving a visible
            // "cancelled" state before any player sample arrives.
            if lastError == URLError(.cancelled).localizedDescription {
                lastError = nil
            }
            signalPollWake()
            return
        }
        // Rebuild only when the caller explicitly starts a new polling session
        // or the watchdog has found a dead loop. A normal kick wakes the current
        // scheduler and does not cancel its in-flight request.
        pollTask?.cancel()
        pollDelayTask?.cancel()
        pollDelayTask = nil
        pollWakePending = false
        pollGeneration &+= 1
        let generation = pollGeneration
        isPolling = true
        pollingStartedAt = .now
        lastSuccessfulPollAt = nil
        lastPollSummary = "Checking Spotify playback…"
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollCycle(generation: generation)
                guard !Task.isCancelled,
                      self?.pollGeneration == generation else { return }
                // Poll more often while stopped or paused so a new Spotify
                // session reaches the Live Activity quickly. Steady playback
                // stays at the lower-rate cadence because the app and Activity
                // use the shared wall-clock schedule between polls.
                let fast = self?.usesRapidProbe == true || self?.isStalledPause == true
                let notPlaying = self?.status?.state != .playing
                let aggressive = self?.aggressiveBackgroundMode == true
                let interval = fast
                    ? 0.7
                    : aggressive
                        ? (notPlaying ? 0.8 : 1.0)
                        : (notPlaying ? 1.2 : 3.0)
                await self?.waitForNextPoll(
                    interval: .seconds(interval),
                    generation: generation
                )
            }
        }
    }

    /// Waits for the regular cadence or one coalesced wake request. The old
    /// implementation created a new AsyncStream iterator on every cycle. Once
    /// an iterator was cancelled, later iterators could finish immediately and
    /// issue several Spotify requests per second.
    private func waitForNextPoll(
        interval: Duration,
        generation: UInt64
    ) async {
        guard ownsPoll(generation) else { return }
        if pollWakePending {
            pollWakePending = false
            return
        }
        let delay = Task<Void, Never> {
            _ = try? await Task.sleep(for: interval)
        }
        pollDelayTask = delay
        await delay.value
        guard generation == pollGeneration else { return }
        pollDelayTask = nil
        pollWakePending = false
    }

    private func signalPollWake() {
        pollWakePending = true
        pollDelayTask?.cancel()
    }

    private static func makePlayerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 9
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func resetPlayerSession() {
        playerSession.invalidateAndCancel()
        playerSession = Self.makePlayerSession()
        DiagnosticsLog.append("Spotify network session reset")
    }

    /// One full poll wrapped in a hard timeout. A hung URLSession request can
    /// never stall the scheduling loop — the group cancels it after 12s and
    /// the loop moves on regardless of the outcome.
    private func pollCycle(generation: UInt64) async {
        // Heartbeat for liveness checks: a fresh stamp at each iteration start.
        guard ownsPoll(generation) else { return }
        lastLoopActivityAt = .now
        // A recovery burst is a bounded number of poll cycles, not a number
        // of successful HTTP responses. Network failures and Spotify 429s
        // must not leave the provider in rapid mode forever.
        defer { consumeRapidProbe() }
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await self?.poll(generation: generation)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !completed, ownsPoll(generation) {
            lastPollSummary = "Spotify check timed out. Retrying…"
            DiagnosticsLog.append("Spotify playback check timed out")
            resetPlayerSession()
        }
    }

    /// When the polling loop last showed life. Requests are capped at 12s and
    /// backoffs at 15s, so a heartbeat older than this means the loop is
    /// genuinely dead or hung — not merely waiting on a slow request.
    private(set) var lastLoopActivityAt: Date?
    private(set) var pollingStartedAt: Date?
    static let loopStaleThreshold: TimeInterval = 20

    var isLoopLikelyAlive: Bool {
        guard let last = lastLoopActivityAt else { return false }
        return Date.now.timeIntervalSince(last) < Self.loopStaleThreshold
    }

    /// Immediate poll: wakes the current scheduling loop so the next request
    /// fires now instead of after the current inter-poll sleep. It does not
    /// cancel an in-flight request; this is important during skip bursts.
    func kick() {
        burst()
        if isPolling, isLoopLikelyAlive {
            signalPollWake()
        } else {
            start()
        }
    }

    /// Changes the polling profile without starting a second loop. Callers
    /// can follow this with `kick()` when an immediate poll is needed.
    func setAggressiveBackgroundMode(_ enabled: Bool) {
        guard aggressiveBackgroundMode != enabled else { return }
        aggressiveBackgroundMode = enabled
        let profile = enabled ? "aggressive" : "normal"
        DiagnosticsLog.append("spotify polling profile: \(profile)")
    }

    private(set) var usesRapidProbe = false
    /// Opt-in high-power polling used while the app keeps its background
    /// background session alive. The local Live Activity schedule still renders
    /// between polls; this mode is for faster play, pause, skip, and seek
    /// detection when the phone is locked.
    private(set) var aggressiveBackgroundMode = false
    private var rapidProbesLeft = 0
    private var lastAppliedItemKey: String?
    /// Last raw position Spotify reported, for frozen/backwards lie detection.
    private var lastAppliedPositionMs: Int?
    /// Timestamp of the last successful (HTTP 200) player-state fetch.
    private(set) var lastSuccessfulPollAt: Date?
    /// Spotify's event clock for the accepted player state. This changes on
    /// play, pause, skip, scrub, and a new item. It lets the app distinguish a
    /// real transport event from a normal progress sample without using the
    /// event date as the progress observation date.
    private(set) var lastPlaybackChangeAt: Date?
    private var lastPlaybackChangeTimestampMs: Int64?

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
    private var pendingSkipCommandID: UUID?
    private var pendingSkipRecoveryStatus: PlaybackStatus?
    static let skipEchoWindow: TimeInterval = 25

    /// A transport command changes the local playback projection before the
    /// Spotify response arrives. Keep that projection until a matching player
    /// sample confirms it, or for a short bounded window when the API is slow.
    /// This makes pause/play feel immediate without allowing a stale sample to
    /// undo the user's action.
    private struct PendingTransportState {
        let id: UUID
        let trackKey: String?
        let expectedState: PlaybackStatus.State
        let expectedPosition: TimeInterval?
        let issuedAt: Date
        let previousStatus: PlaybackStatus
        let deadline: Date
    }
    private var pendingTransportState: PendingTransportState?
    static let transportConfirmationWindow: TimeInterval = 8
    /// A backward sample up to this size can be transport jitter. A larger
    /// change is a user seek and must reach the lyric clock immediately.
    private static let positionJitterThresholdMs = 750

    /// Spotify transport requests are asynchronous and the system can deliver
    /// several headphone, Lock Screen, or widget commands before the first
    /// response arrives. Running them concurrently lets responses complete in
    /// the wrong order, restarts the poller repeatedly, and leaves skip echo
    /// protection attached to the wrong command. Keep one FIFO tail for all
    /// transport commands so each command observes the state produced by the
    /// previous command.
    private var transportQueueTail: Task<Bool, Never>?
    private var transportQueueGeneration: UInt64 = 0

    /// Schedules N fast polls so a user-initiated change (transport command,
    /// audio interruption) shows up in ≤N×0.7s instead of waiting out the 3s cadence.
    func burst(count: Int = 6) {
        rapidProbesLeft = max(rapidProbesLeft, count)
        usesRapidProbe = true
    }

    private func consumeRapidProbe() {
        guard rapidProbesLeft > 0 else { return }
        rapidProbesLeft -= 1
        guard rapidProbesLeft == 0 else { return }

        usesRapidProbe = false
        // A real pause and a stale pause look identical after the bounded
        // probe window. Return to normal polling so a later play transition
        // is detected without a permanent high-rate request loop.
        stalePauseProbeArmed = false
        isStalledPause = false
        stalledPauseCount = 0
        didLogStall = false
    }

    // MARK: Stalled stale-API pause detection
    // Spotify sometimes serves the old track as "paused" at a frozen position
    // for many seconds after a skip. If we treat that as a real pause the card
    // freezes; N consecutive identical frozen positions = API is lying.
    private var stalledPauseCount = 0
    private var lastFrozenPos: Int?
    private var didLogStall = false
    /// True only during the bounded probe after a playing-to-paused
    /// transition. A normal pause must not permanently force rapid polling.
    private var stalePauseProbeArmed = false
    /// True while we believe the API is serving a stale paused state.
    private(set) var isStalledPause = false
    static let stallThreshold = 4

    private func beginRapidProbe(staleItem: String?) {
        guard rapidProbesLeft == 0 else { return }
        rapidProbesLeft = 25
        usesRapidProbe = true
        stalePauseProbeArmed = true
        stalledPauseCount = 0
        lastFrozenPos = nil
        isStalledPause = false
        didLogStall = false
        DiagnosticsLog.append("rapid probe: api reports paused \(staleItem ?? "?") after playing")
    }

    func stop() {
        pollGeneration &+= 1
        pollTask?.cancel()
        pollDelayTask?.cancel()
        pollDelayTask = nil
        pollWakePending = false
        pollTask = nil
        isPolling = false
        // A cancelled loop must stop renewing the phone ownership lease
        // immediately. Keeping the old stamp makes the server believe the
        // phone is still authoritative during the stale threshold.
        lastLoopActivityAt = nil
        pollingStartedAt = nil
    }

    private func poll(generation: UInt64) async {
        do {
            let (data, http) = try await requestPlayerState()
            guard ownsPoll(generation) else {
                DiagnosticsLog.append("stale Spotify response rejected")
                return
            }
            switch http.statusCode {
            case 200:
                var state = try JSONDecoder().decode(SpotifyPlayerState.self, from: data)
                // Spotify can return a partial player object during a device
                // transition. Do not treat an omitted field as a real pause
                // or a jump to zero. Merge only with the accepted same-track
                // state before stall, skip, and lyric scheduling logic runs.
                let incomingItem = state.item
                let incomingTitle = incomingItem?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let incomingArtist = incomingItem?.artists?.first?.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sameAcceptedTrack = PlaybackTransitionPolicy.isSameTrack(
                    incomingID: incomingItem?.id,
                    acceptedID: metadata.trackID,
                    incomingTitle: incomingTitle,
                    incomingArtist: incomingArtist,
                    acceptedSignature: metadata.signature
                )
                if let existingStatus = status, sameAcceptedTrack {
                    if !state.isPlayingWasReported {
                        state.isPlaying = existingStatus.state == .playing
                    }
                    if !state.progressWasReported, existingStatus.state != .stopped {
                        state.progressMs = Int(max(0, existingStatus.position(at: .now)) * 1_000)
                    }
                }
                // Only count frozen paused samples while a stale-pause probe is
                // armed. Counting every normal pause made the provider stay in
                // rapid-poll mode forever. Spotify then rate-limited requests,
                // and a later play transition appeared to be undetected.
                if stalePauseProbeArmed,
                   !state.isPlaying,
                   state.progressMs == lastFrozenPos {
                    stalledPauseCount += 1
                } else if state.isPlaying {
                    stalledPauseCount = 0
                    didLogStall = false
                    stalePauseProbeArmed = false
                    isStalledPause = false
                } else if !stalePauseProbeArmed {
                    stalledPauseCount = 0
                    didLogStall = false
                    isStalledPause = false
                }
                lastFrozenPos = state.progressMs
                if stalePauseProbeArmed {
                    isStalledPause = stalledPauseCount >= Self.stallThreshold
                }
                if isStalledPause, !didLogStall {
                    didLogStall = true
                    DiagnosticsLog.append("stall confirmed: \(stalledPauseCount) frozen polls at pos=\(lastFrozenPos ?? -1)")
                }

                apply(state)
                lastSuccessfulPollAt = .now
                lastPollSummary = state.device?.name.map { "playing on \($0)" } ?? "Spotify playback found"
                DiagnosticsLog.append("poll: item=\(state.item?.name ?? "nil") playing=\(state.isPlaying) pos=\(state.progressMs ?? -1)")
                lastError = nil
                // Transition in progress (stale pause-echo or post-command
                // probes): /me/player may be serving stale slices of the dead
                // track. Cross-check against recently-played, which reports
                // what actually played and flips us onto the real track fast.
                await maybeCrossCheckRecentlyPlayed(generation: generation)
                guard ownsPoll(generation) else { return }
            case 204:
                stalePauseProbeArmed = false
                isStalledPause = false
                stalledPauseCount = 0
                rapidProbesLeft = 0
                usesRapidProbe = false
                status = PlaybackStatus(state: .stopped, position: 0)
                if isPlaybackConfirmedStopped || metadata.observeStopped() {
                    isPlaybackConfirmedStopped = true
                    signature = nil
                    lastAlbumImageURL = nil
                    lastTrackID = nil
                    lastAppliedItemKey = nil
                    lastAppliedPositionMs = nil
                }
                lastSuccessfulPollAt = .now
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
            guard ownsPoll(generation) else { return }
            stop()
            lastError = error.errorDescription
        } catch is CancellationError {
        } catch {
            if Self.isRequestCancellation(error) {
                guard ownsPoll(generation) else { return }
                // URLSession can report NSURLErrorCancelled when iOS moves the
                // scene between active and inactive states. This is a retry
                // signal, not a Spotify failure. Keep the scheduler alive and
                // do not leave "cancelled" as the permanent user-facing state.
                lastError = nil
                burst(count: 3)
                signalPollWake()
                DiagnosticsLog.append("Spotify request cancelled; retry queued")
                return
            }
            guard ownsPoll(generation) else { return }
            lastError = error.localizedDescription
        }
    }

    private static func isRequestCancellation(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    private func ownsPoll(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == pollGeneration && isPolling
    }

    /// Checks the dedicated currently-playing endpoint first. Some Spotify
    /// sessions return an active item there while the full player endpoint is
    /// temporarily empty during a device handoff. A 204 is confirmed against
    /// the full endpoint before OpenLyrics reports that playback stopped.
    /// On a 401, force a real token refresh and retry the pair once.
    private func requestPlayerState() async throws -> (Data, HTTPURLResponse) {
        var token = try await auth.validAccessToken()
        var retried401 = false
        while true {
            var result = try await requestSpotifyPlayer(
                at: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!,
                token: token
            )
            if result.1.statusCode == 204 {
                DiagnosticsLog.append("currently-playing returned 204; checking full player state")
                result = try await requestSpotifyPlayer(
                    at: URL(string: "https://api.spotify.com/v1/me/player")!,
                    token: token
                )
            }
            let (data, http) = result
            guard http.statusCode == 401, !retried401 else {
                return (data, http)
            }
            retried401 = true
            auth.invalidateAccessToken()
            token = try await auth.validAccessToken()
        }
    }

    private func requestSpotifyPlayer(
        at url: URL,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 7
        let endpoint = url.lastPathComponent
        let startedAt = Date.now
        do {
            let (data, response) = try await playerSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LyricsLookupError(kind: .network("invalid response"))
            }
            let elapsed = Date.now.timeIntervalSince(startedAt)
            if elapsed >= 2 || http.statusCode != 200 {
                DiagnosticsLog.append(
                    "Spotify \(endpoint) HTTP \(http.statusCode) in \(String(format: "%.1f", elapsed))s"
                )
            }
            return (data, http)
        } catch {
            let elapsed = Date.now.timeIntervalSince(startedAt)
            DiagnosticsLog.append(
                "Spotify \(endpoint) failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)"
            )
            throw error
        }
    }

    /// Keeps a local play/pause projection in place while Spotify is still
    /// returning the previous state. A different track always wins, and a
    /// completed track is never held in the optimistic state.
    private func reconcileOptimisticPlayback(with state: SpotifyPlayerState) -> Bool {
        guard let pending = pendingTransportState else { return false }

        let observedKey = itemKey(for: state.item)
        let sameTextualTrack = metadata.signature?.title == state.item?.name
            && metadata.signature?.artist == state.item?.artists?.first?.name
            && (metadata.signature?.album == nil
                || state.item?.album?.name == nil
                || metadata.signature?.album == state.item?.album?.name)
        let observedStableID = state.item?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptedStableID = metadata.trackID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameTrack = observedKey == pending.trackKey
            || (sameTextualTrack && (observedStableID?.isEmpty != false || acceptedStableID?.isEmpty != false))
        guard sameTrack else {
            pendingTransportState = nil
            DiagnosticsLog.append("transport confirmed track change")
            return false
        }

        if state.isCompleted || state.status.state == .stopped {
            pendingTransportState = nil
            return false
        }

        let stateMatches = state.status.state == pending.expectedState
        let positionMatches: Bool
        if let expectedPosition = pending.expectedPosition,
           let progressMs = state.progressMs {
            let elapsed = pending.expectedState == .playing
                ? max(0, Date.now.timeIntervalSince(pending.issuedAt))
                : 0
            let projectedPosition = expectedPosition + elapsed
            positionMatches = abs(TimeInterval(progressMs) / 1000 - projectedPosition) <= 1.5
        } else {
            // Play/pause commands do not require a position match. Spotify can
            // return a slightly older progress value while it has already
            // accepted the transport change.
            positionMatches = pending.expectedPosition == nil
        }

        if stateMatches, positionMatches {
            pendingTransportState = nil
            DiagnosticsLog.append("transport confirmed: \(pending.expectedState)")
            return false
        }

        guard Date.now < pending.deadline else {
            pendingTransportState = nil
            DiagnosticsLog.append("transport confirmation timed out")
            return false
        }

        // Keep the polling loop in its fast command-recovery profile while the
        // stale response is being rejected. The local projection remains the
        // source of truth for the app and Live Activity during this window.
        burst(count: 4)
        return true
    }

    private func apply(_ state: SpotifyPlayerState) {
        // The item key can be absent during a Spotify device transition. Keep
        // the accepted track and artwork until Spotify explicitly returns
        // item:null. This also keeps the canonical reducer from interpreting
        // a partial response as a stop.
        if !state.itemWasReported {
            guard let existingStatus = status, signature != nil else { return }
            let playing = state.isPlayingWasReported
                ? state.isPlaying
                : existingStatus.state == .playing
            let position = state.progressWasReported
                ? TimeInterval(state.progressMs ?? 0) / 1_000
                : existingStatus.position(at: .now)
            status = PlaybackStatus(
                state: playing ? .playing : .paused,
                position: max(0, position),
                rate: playing ? max(existingStatus.rate, 1) : 0
            )
            DiagnosticsLog.append("partial Spotify response preserved current item")
            return
        }

        // Post-skip echo rejection runs before anything else: a poll that
        // still shows the pre-skip track carries zero information, so don't
        // let it touch stall bookkeeping, the lie guard, or status/signature.
        if let pending = pendingSkipItemKey {
            let expired = Date.now >= (pendingSkipDeadline ?? .distantPast)
            // Repeat-one: same item, playing, restarted near 0 — real truth.
            let restart = state.isPlaying && (state.progressMs ?? 999_999) < 5_000
            if expired || itemKey(for: state.item) != pending || restart {
                pendingSkipItemKey = nil
                pendingSkipDeadline = nil
                pendingSkipCommandID = nil
                pendingSkipRecoveryStatus = nil
                DiagnosticsLog.append("skip resolved: \(state.item?.name ?? "?")")
            } else {
                rapidProbesLeft = max(rapidProbesLeft, 3)
                DiagnosticsLog.append("skip echo ignored: \(state.item?.name ?? "?") pos=\(state.progressMs ?? -1)")
                return
            }
        }

        if reconcileOptimisticPlayback(with: state) {
            return
        }

        // Fresh playing state ends any stall episode immediately.
        if state.isPlaying {
            stalledPauseCount = 0
            isStalledPause = false
            didLogStall = false
            stalePauseProbeArmed = false
        }
        let wasPlaying = status?.state == .playing
        let itemName = state.item?.name
        let identityKey = itemKey(for: state.item)
        // Old track flips to "paused" right after it was playing → classic
        // stale-API skip transition; probe fast until real state arrives.
        if wasPlaying, state.isPlaying == false, !state.isCompleted,
           let identityKey, identityKey == lastAppliedItemKey {
            beginRapidProbe(staleItem: itemName)
        }
        guard let identityKey, let item = state.item else {
            stalePauseProbeArmed = false
            isStalledPause = false
            stalledPauseCount = 0
            status = state.status
            if isPlaybackConfirmedStopped || metadata.observeStopped() {
                isPlaybackConfirmedStopped = true
                signature = nil
                lastAlbumImageURL = nil
                lastTrackID = nil
                lastAppliedItemKey = nil
                lastAppliedPositionMs = nil
            }
            recordPlaybackChange(from: state)
            return
        }

        guard let nextSignature = state.signature else {
            // An item can be present while Spotify is still filling in its
            // metadata during a device or track transition. It is not a stop.
            // If the stable ID is the accepted ID, retain the trusted title,
            // artist, album, and artwork instead of feeding the partial sample
            // into the stopped-sample counter.
            let sameAcceptedItem = metadata.trackKey == identityKey
                || (item.id != nil && item.id == metadata.trackID)
            if sameAcceptedItem, let existingStatus = status {
                let playing = state.isPlayingWasReported
                    ? state.isPlaying
                    : existingStatus.state == .playing
                let position = state.progressWasReported
                    ? state.status.position
                    : existingStatus.position(at: .now)
                status = PlaybackStatus(
                    state: playing ? .playing : .paused,
                    position: position,
                    rate: playing ? max(existingStatus.rate, 1) : 0
                )
                DiagnosticsLog.append("partial Spotify item preserved: \(identityKey)")
            } else {
                // A stable ID for a different item is enough to reject the
                // previous artwork. Wait for complete metadata before loading
                // lyrics, but do not show the old album for the new track.
                status = state.status
                signature = nil
                lastAlbumImageURL = nil
                lastTrackID = item.id
                lastAppliedItemKey = identityKey
            }
            recordPlaybackChange(from: state)
            return
        }

        let canonicalReduction = unifiedPlayback.reduce(
            state.playbackObservation(receivedAt: .now)
        )
        if canonicalReduction.kind == .ignoredStale {
            DiagnosticsLog.append("canonical playback reducer rejected stale sample")
            return
        }
        canonicalPlaybackRevision = canonicalReduction.snapshot?.revision
            ?? canonicalPlaybackRevision

        // A paused item near its duration is ambiguous. Spotify can return
        // this sample both after natural completion and after the user pauses
        // during the final fraction of a song. Do not end the session from
        // that one sample. A confirmed stop requires the separate no-item
        // response path below, which also protects the artwork and LA state.
        isPlaybackConfirmedStopped = false

        // Position-lie guard: while playing on the SAME track, a frozen or
        // slightly-backwards position is a stale seek/scrub echo, not truth —
        // never let the displayed position regress because of it.
        let newPos = state.progressMs
        if state.isPlaying, identityKey == lastAppliedItemKey,
           let newPos, let last = lastAppliedPositionMs,
           newPos <= last,
           abs(newPos - last) <= Self.positionJitterThresholdMs {
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
        // Spotify can briefly omit progress_ms while it still returns the
        // current item. Do not convert that partial response to position zero:
        // keep projecting the last trusted position until a new sample arrives.
        if state.progressMs == nil, let existingStatus = status, existingStatus.state == .playing {
            status = PlaybackStatus(
                state: state.isPlaying ? .playing : .paused,
                position: existingStatus.position(at: .now),
                rate: state.isPlaying ? max(existingStatus.rate, 0.001) : 0
            )
        } else if state.isCompleted {
            // Spotify's value-level status maps this sample to stopped for
            // compatibility. The provider keeps it paused until Spotify
            // confirms that there is no active item, so a manual near-end
            // pause does not remove the Live Activity.
            status = PlaybackStatus(
                state: .paused,
                position: TimeInterval(state.progressMs ?? 0) / 1_000,
                rate: 0
            )
        } else {
            status = state.status
        }
        // Spotify can omit the item ID in a short same-track response. Pass
        // the response's complete textual key to the shared reducer. It
        // preserves the accepted ID for compatible partial data, but rejects
        // an explicitly different album or duration instead of inheriting the
        // previous track's artwork.
        metadata.accept(
            trackKey: identityKey,
            trackID: item.id,
            signature: nextSignature,
            albumImageURL: state.albumImageURL
        )
        lastAppliedItemKey = metadata.trackKey
        lastTrackID = metadata.trackID
        signature = metadata.signature
        lastAlbumImageURL = metadata.albumImageURL
        recordPlaybackChange(from: state)
    }

    /// Records Spotify's monotonic event timestamp after a sample is accepted.
    /// The API can return an invalid zero value or a small future value while
    /// clocks are settling; those values must not cause repeated urgent sends.
    private func recordPlaybackChange(from state: SpotifyPlayerState) {
        guard let timestampMs = state.timestampMs, timestampMs > 0 else { return }
        if let previous = lastPlaybackChangeTimestampMs, timestampMs < previous {
            DiagnosticsLog.append("stale Spotify event timestamp rejected")
            return
        }
        guard timestampMs != lastPlaybackChangeTimestampMs else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1_000)
        guard date.timeIntervalSince1970.isFinite,
              date <= Date.now.addingTimeInterval(60) else {
            DiagnosticsLog.append("invalid Spotify event timestamp rejected")
            return
        }
        let isFollowUpEvent = lastPlaybackChangeTimestampMs != nil
        lastPlaybackChangeTimestampMs = timestampMs
        lastPlaybackChangeAt = date
        DiagnosticsLog.append("Spotify playback event: \(timestampMs)")
        // An event timestamp changes for play, pause, seek, and track changes.
        // Start a short probe window even when the command came from Spotify
        // or headphones, because those actions do not pass through our own
        // command handlers and therefore cannot arm skip-echo protection.
        if isFollowUpEvent {
            burst(count: 8)
        }
    }

    @ObservationIgnored private var staleSeekCount = 0
    @ObservationIgnored private var suppressedLieSamples = 0

    /// Album cover URL from the most recent poll (for the vinyl widget etc).
    private(set) var lastAlbumImageURL: String?
    /// Stable Spotify item ID for state arbitration and server diagnostics.
    private(set) var lastTrackID: String?
    /// True only after two trustworthy stopped samples. Startup and a single
    /// Spotify 204 response are not enough to end a playback session.
    private(set) var isPlaybackConfirmedStopped = false

    // MARK: Transport commands (remote command center / widget buttons)

    private func enqueueTransport(_ operation: @escaping () async -> Bool) async -> Bool {
        let previous = transportQueueTail
        transportQueueGeneration &+= 1
        let generation = transportQueueGeneration
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, self != nil else { return false }
            return await operation()
        }
        transportQueueTail = task

        let result = await task.value
        // Only the final queued command clears the tail. Earlier commands can
        // finish while later commands are still waiting behind them.
        if transportQueueGeneration == generation {
            transportQueueTail = nil
        }
        return result
    }

    /// Seeks Spotify playback to the given position. Returns true when the
    /// request was accepted (204).
    @discardableResult
    func seek(to position: TimeInterval) async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performSeek(to: position)
        }
    }

    private func performSeek(to position: TimeInterval) async -> Bool {
        let optimisticID = beginOptimisticSeek(to: position)
        let ok = await transportCall(
            url: URL(string: "https://api.spotify.com/v1/me/player/seek?position_ms=\(Int(max(0, position) * 1000))")!
        )
        if let optimisticID {
            finishOptimisticTransport(id: optimisticID, accepted: ok)
        }
        return ok
    }

    /// Skips to the next track.
    @discardableResult
    func next() async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performNext()
        }
    }

    private func performNext() async -> Bool {
        let optimisticID = beginPendingSkip()
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/next")!, method: "POST")
        if !ok, let optimisticID {
            rollbackPendingSkip(id: optimisticID)
        }
        return ok
    }

    /// Skips back to the previous track.
    @discardableResult
    func previous() async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performPrevious()
        }
    }

    private func performPrevious() async -> Bool {
        let optimisticID = beginPendingSkip()
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/previous")!, method: "POST")
        if !ok, let optimisticID {
            rollbackPendingSkip(id: optimisticID)
        }
        return ok
    }

    /// Arms stale-echo rejection for a fresh skip: freeze the displayed
    /// position immediately (the LA flips to its static bar via the urgent
    /// play-change path) and discard polls still echoing the pre-skip track.
    private func beginPendingSkip() -> UUID? {
        guard let preSkip = lastAppliedItemKey else { return nil }
        let commandID = UUID()
        pendingTransportState = nil
        pendingSkipItemKey = preSkip
        pendingSkipDeadline = .now.addingTimeInterval(Self.skipEchoWindow)
        pendingSkipCommandID = commandID
        pendingSkipRecoveryStatus = status
        burst(count: 10)
        if let status, status.state == .playing {
            self.status = PlaybackStatus(state: .paused, position: status.position(at: .now))
        }
        DiagnosticsLog.append("skip armed: freezing over \(preSkip)")
        return commandID
    }

    private func rollbackPendingSkip(id: UUID) {
        guard pendingSkipCommandID == id else { return }
        pendingSkipItemKey = nil
        pendingSkipDeadline = nil
        pendingSkipCommandID = nil
        if let pendingSkipRecoveryStatus {
            status = pendingSkipRecoveryStatus
        }
        pendingSkipRecoveryStatus = nil
        DiagnosticsLog.append("skip rejected: restored current track")
        burst(count: 4)
        kick()
    }

    /// Projects a play or pause command immediately. Spotify's player endpoint
    /// can acknowledge the command before its next state sample changes.
    private func beginOptimisticPlayback(to target: PlaybackStatus.State) -> UUID? {
        guard target == .playing || target == .paused,
              let current = status,
              current.state != .stopped,
              current.state != target else { return nil }

        let now = Date.now
        let projected = PlaybackStatus(
            state: target,
            position: max(0, current.position(at: now)),
            rate: target == .playing ? max(current.rate, 1) : 0,
            timestamp: now
        )
        let id = UUID()
        pendingTransportState = PendingTransportState(
            id: id,
            trackKey: lastAppliedItemKey,
            expectedState: target,
            expectedPosition: nil,
            issuedAt: now,
            previousStatus: current,
            deadline: now.addingTimeInterval(Self.transportConfirmationWindow)
        )
        status = projected
        isPlaybackConfirmedStopped = false
        burst(count: 10)
        DiagnosticsLog.append("optimistic transport: \(target)")
        return id
    }

    /// Projects a seek immediately, then holds it until Spotify reports the
    /// requested position. A stale position sample cannot move the UI back.
    private func beginOptimisticSeek(to position: TimeInterval) -> UUID? {
        guard let current = status, current.state != .stopped else { return nil }
        let targetPosition = max(0, position)
        let now = Date.now
        let projected = PlaybackStatus(
            state: current.state,
            position: targetPosition,
            rate: current.state == .playing ? max(current.rate, 1) : 0,
            timestamp: now
        )
        let id = UUID()
        pendingTransportState = PendingTransportState(
            id: id,
            trackKey: lastAppliedItemKey,
            expectedState: current.state,
            expectedPosition: targetPosition,
            issuedAt: now,
            previousStatus: current,
            deadline: now.addingTimeInterval(Self.transportConfirmationWindow)
        )
        status = projected
        burst(count: 10)
        DiagnosticsLog.append("optimistic seek: \(String(format: "%.2f", targetPosition))s")
        return id
    }

    private func finishOptimisticTransport(id: UUID, accepted: Bool) {
        guard let pending = pendingTransportState, pending.id == id else { return }
        guard !accepted else { return }
        pendingTransportState = nil
        status = pending.previousStatus
        DiagnosticsLog.append("optimistic transport rejected: restored \(pending.previousStatus.state)")
        burst(count: 4)
        kick()
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
    private static let aggressiveRecentlyPlayedInterval: TimeInterval = 5

    private func maybeCrossCheckRecentlyPlayed(generation: UInt64) async {
        guard ownsPoll(generation) else { return }
        // A commanded skip already has echo protection. External skips do not
        // pass through this process, so the aggressive session needs a small
        // bounded history check as well. The five-second interval keeps this
        // useful while locked without turning the one-second player poll into
        // a second high-rate Spotify request stream.
        let isTransition = isStalledPause || rapidProbesLeft > 0
        guard isTransition || aggressiveBackgroundMode else { return }
        if let last = lastRecentlyPlayedCheckAt,
           Date.now.timeIntervalSince(last) < (isTransition ? 2.5 : Self.aggressiveRecentlyPlayedInterval) {
            return
        }

        // The history endpoint has no playback-state field. Only use it to
        // repair a track that the player endpoint still reports as playing;
        // a paused user may simply have an older recently-played entry.
        guard status?.state == .playing || isStalledPause else { return }
        let now = Date.now
        lastRecentlyPlayedCheckAt = now

        guard let token = try? await auth.validAccessToken(),
              ownsPoll(generation) else { return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=5")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              ownsPoll(generation),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RecentlyPlayedResponse.self, from: data),
              let newest = decoded.items.first else { return }

        guard let name = newest.track?.name,
              let playedAt = newest.playedAt else { return }
        let recentlyPlayedKey = itemKey(
            id: newest.track?.id,
            name: name,
            artist: newest.track?.artists?.first?.name ?? "",
            album: newest.track?.album?.name
        )
        guard recentlyPlayedKey != lastAppliedItemKey else { return } // no skip happened
        // Only fresh plays count as skips; older history entries are noise.
        // Also require the entry to be newer than the estimated start of the
        // track that /me/player still reports. This prevents a previously
        // played song from replacing a legitimate long-running track merely
        // because it is still inside the freshness window.
        guard let currentStatus = status,
              PlaybackTransitionPolicy.acceptsRecentlyPlayed(
                  playedAt: playedAt,
                  now: now,
                  currentTrackPosition: max(0, currentStatus.position(at: now))
              ) else {
            DiagnosticsLog.append("recently-played: \(name) outside current-track window")
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
        let nextSignature = TrackSignature(
            title: name,
            artist: track.artists?.first?.name ?? "",
            album: track.album?.name,
            duration: duration
        )
        pendingTransportState = nil
        pendingSkipCommandID = nil
        pendingSkipRecoveryStatus = nil
        signature = nextSignature
        status = PlaybackStatus(
            state: .playing,
            position: min(elapsed, duration ?? elapsed),
            rate: 1.0
        )
        let nextArtworkURL = track.album?.images?
            .last(where: { ($0.width ?? 0) >= 300 })?.url
            ?? track.album?.images?.last?.url
        let nextTrackKey = itemKey(
            id: track.id,
            name: name,
            artist: track.artists?.first?.name ?? "",
            album: track.album?.name
        )
        metadata.replace(
            trackKey: nextTrackKey,
            trackID: track.id,
            signature: nextSignature,
            albumImageURL: nextArtworkURL
        )
        isPlaybackConfirmedStopped = false
        lastAppliedItemKey = metadata.trackKey
        lastTrackID = metadata.trackID
        lastAlbumImageURL = metadata.albumImageURL
        lastAppliedPositionMs = Int(min(elapsed, duration ?? elapsed) * 1000)
        stalledPauseCount = 0
        isStalledPause = false
        didLogStall = false
        burst(count: 8)
        DiagnosticsLog.append("recently-played flip: \(name) est=\(Int(elapsed))s")
    }

    private func itemKey(for item: SpotifyPlayerState.Item?) -> String? {
        guard let item else { return nil }
        return itemKey(
            id: item.id,
            name: item.name ?? "",
            artist: item.artists?.first?.name ?? "",
            album: item.album?.name
        )
    }

    private func itemKey(id: String?, name: String, artist: String, album: String?) -> String {
        id ?? "\(name)|\(artist)|\(album ?? "")"
    }

    private func transportCall(url: URL, method: String = "PUT") async -> Bool {
        guard var token = try? await auth.validAccessToken() else { return false }
        var retried401 = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return false }
                if http.statusCode == 401, !retried401 {
                    retried401 = true
                    auth.invalidateAccessToken()
                    guard let refreshed = try? await auth.validAccessToken() else { return false }
                    token = refreshed
                    continue
                }
                if (200...299).contains(http.statusCode) {
                    burst()
                    kick()
                    return true
                }
                if http.statusCode == 403 {
                    lastError = "Playback control not permitted. Sign out and sign in again to grant Spotify playback control."
                }
                return false
            } catch {
                return false
            }
        }
    }

    /// Toggles play/pause via the Spotify Web API. Returns true when a request
    /// went out and got accepted (204); false when there was nothing to control.
    @discardableResult
    func togglePlayPause() async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performTogglePlayPause()
        }
    }

    private func performTogglePlayPause() async -> Bool {
        let base = URL(string: "https://api.spotify.com/v1/me/player")!
        let target: URL
        let targetState: PlaybackStatus.State
        if status?.state == .playing {
            target = base.appendingPathComponent("pause")
            targetState = .paused
        } else {
            target = base.appendingPathComponent("play")
            targetState = .playing
        }

        let optimisticID = beginOptimisticPlayback(to: targetState)
        let ok = await transportCall(url: target, method: "PUT")
        if let optimisticID {
            finishOptimisticTransport(id: optimisticID, accepted: ok)
        }
        return ok
    }

    @discardableResult
    func play() async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performPlay()
        }
    }

    private func performPlay() async -> Bool {
        let optimisticID = beginOptimisticPlayback(to: .playing)
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/play")!, method: "PUT")
        if let optimisticID {
            finishOptimisticTransport(id: optimisticID, accepted: ok)
        }
        return ok
    }

    @discardableResult
    func pause() async -> Bool {
        await enqueueTransport { [weak self] in
            guard let self else { return false }
            return await self.performPause()
        }
    }

    private func performPause() async -> Bool {
        let optimisticID = beginOptimisticPlayback(to: .paused)
        let ok = await transportCall(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!, method: "PUT")
        if let optimisticID {
            finishOptimisticTransport(id: optimisticID, accepted: ok)
        }
        return ok
    }
}

/// Playback capabilities consumed by the app's lyrics, widget, and Live
/// Activity pipeline. Keeping this contract provider-neutral lets another
/// service supply the same normalized track/status/transport data later.
@MainActor
protocol PlaybackProvider: AnyObject {
    var signature: TrackSignature? { get }
    var status: PlaybackStatus? { get }
    var lastError: String? { get }
    var lastPollSummary: String? { get }
    var isPolling: Bool { get }
    var pollingStartedAt: Date? { get }
    var lastSuccessfulPollAt: Date? { get }
    var lastPlaybackChangeAt: Date? { get }
    var lastAlbumImageURL: String? { get }
    var lastTrackID: String? { get }
    var isPlaybackConfirmedStopped: Bool { get }
    var isLoopLikelyAlive: Bool { get }

    func start()
    func stop()
    func kick()
    func setAggressiveBackgroundMode(_ enabled: Bool)
    func burst(count: Int)
    func next() async -> Bool
    func previous() async -> Bool
    func seek(to position: TimeInterval) async -> Bool
    func togglePlayPause() async -> Bool
    func play() async -> Bool
    func pause() async -> Bool
}

extension PlaybackProvider {
    func burst() {
        burst(count: 6)
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

            struct Artist: Codable, Sendable {
                var name: String

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                }

                private enum CodingKeys: String, CodingKey {
                    case name
                }
            }
            struct Album: Codable, Sendable {
                var name: String?
                var images: [Image]?
                struct Image: Codable, Sendable {
                    var url: String?
                    var width: Int?
                }
            }

            enum CodingKeys: String, CodingKey {
                case id, name, artists, album
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
