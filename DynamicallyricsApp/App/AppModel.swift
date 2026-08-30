import SwiftUI
import WidgetKit
import LyricCore

/// Facade wiring Spotify auth + polling + lyrics into a single observable model.
@MainActor
@Observable
final class AppModel {
    let auth = SpotifyAuthManager()
    let lyrics = LyricsService()
    let liveActivity = LiveActivityController()
    private(set) var provider: (any PlaybackProvider)?
    private let watchSync = WatchSyncManager.shared
    private let nowPlaying = NowPlayingBridge()
    @ObservationIgnored private var albumArtworkPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastArtworkPrefetchURL: String?
    @ObservationIgnored private var lastArtworkPrefetchAt: Date?

    private(set) var connectError: String?
    var isConnecting = false

    private(set) var signature: TrackSignature?
    private(set) var status: PlaybackStatus?

    private var ticker: Task<Void, Never>?
    private var lastLineIndex: Int?
    private var pausedAt: Date?
    private var stoppedAt: Date?
    private let keeper = BackgroundAudioKeeper.shared
    private var widgetPausedAt: Date?
    private var lastPublishedWidgetKey: String?
    @ObservationIgnored private var lastWidgetPublishedPosition: TimeInterval?
    @ObservationIgnored private var lastWidgetPublishedAt: Date?
    @ObservationIgnored private var lastWidgetPublishedRate: Double = 1
    private var widgetIdlePublished = false

    private(set) var demoActive = false
    private static let localSessionEnabledKey = "experimentalLocalLyricsSessionEnabled"
    private(set) var localSessionActive = false

    /// Keeps the phone-owned lyric session active after the screen locks.
    /// This is an explicit beta setting because it uses the audio background
    /// mode and can increase battery use.
    var localSessionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.localSessionEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.localSessionEnabledKey)
            localSessionActive = newValue
            provider?.setAggressiveBackgroundMode(
                newValue && localSessionActive && lockScreenLyricsEnabled && scenePhase != .active
            )
            if !newValue {
                keeper.stop()
            } else {
                DiagnosticsLog.append("local session enabled")
                provider?.kick()
            }
        }
    }

    var lockScreenLyricsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockScreenLyricsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "lockScreenLyricsEnabled")
            if !newValue {
                liveActivity.end()
                localSessionActive = false
                keeper.stop()
            }
            updatePollingProfile()
            if let provider {
                let healthy = provider.lastSuccessfulPollAt.map {
                    Date.now.timeIntervalSince($0) <= 10
                } ?? false
                SyncServerClient.shared.heartbeat(
                    activityState: liveActivity.syncActivityState,
                    trackID: provider.lastTrackID,
                    lyricOffset: lyrics.userOffset,
                    localRevision: localLARevision,
                    healthy: healthy,
                    autoStartEnabled: newValue,
                    force: true
                )
            }
        }
    }

    init() {
        localSessionActive = localSessionEnabled
        startTicker()
        watchSync.activateIfNeeded()
        installNowPlayingBridge()
        if auth.isConnected {
            startPolling()
            SyncServerClient.shared.refreshRegistration()
        }
        if ProcessInfo.processInfo.arguments.contains("-demoActivity") {
            startDemo()
        }
    }

    /// Routes lock-screen/transport events into Spotify control. Fires a fast
    /// poll burst per event so the LA reflects the change in ≤1.5s.
    private func installNowPlayingBridge() {
        nowPlaying.install(
            toggle: { [weak self] in
                guard let self else { return }
                DiagnosticsLog.append("cmd: toggle")
                if let current = self.provider?.status {
                    SharedNowPlaying.setPlayingOverride(current.state != .playing)
                }
                Task {
                    let accepted = await self.provider?.togglePlayPause() ?? false
                    if !accepted { SharedNowPlaying.setPlayingOverride(nil) }
                }
            },
            play: { [weak self] in
                guard let self else { return }
                DiagnosticsLog.append("cmd: play")
                if self.provider?.status != nil {
                    SharedNowPlaying.setPlayingOverride(true)
                }
                Task {
                    if await self.provider?.play() != true {
                        SharedNowPlaying.setPlayingOverride(nil)
                    }
                }
            },
            pause: { [weak self] in
                guard let self else { return }
                DiagnosticsLog.append("cmd: pause")
                if self.provider?.status != nil {
                    SharedNowPlaying.setPlayingOverride(false)
                }
                Task {
                    if await self.provider?.pause() != true {
                        SharedNowPlaying.setPlayingOverride(nil)
                    }
                }
            },
            next: { [weak self] in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: next")
                Task { if await provider.next() { provider.burst() } }
            },
            previous: { [weak self] in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: prev")
                Task { if await provider.previous() { provider.burst() } }
            },
            changePosition: { [weak self] position in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: seek \(Int(position))s")
                Task { if await provider.seek(to: position) { provider.burst() } }
            }
        )
    }

    var offset: TimeInterval {
        get { lyrics.userOffset }
        set { lyrics.userOffset = newValue }
    }

    func connect() async {
        guard SpotifyConfig.isConfigured else {
            connectError = "Add your Spotify Client ID in SpotifyConfig.swift first."
            return
        }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            try await auth.connect()
            startPolling()
            SyncServerClient.shared.refreshRegistration()
        } catch {
            connectError = error.localizedDescription
        }
    }

    func disconnect() {
        provider?.stop()
        provider = nil
        localSessionActive = false
        auth.disconnect()
        signature = nil
        status = nil
        lyrics.update(signature: nil, status: nil)
        nowPlaying.clear()
        liveActivity.end()
        keeper.stop()
        SharedNowPlaying.clearAll()
        watchSync.clear()
        reloadWidgetTimelines()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        updatePollingProfile()
        switch phase {
        case .active:
            if auth.isConnected { startPolling() }
        case .background:
            // Keep the local writer alive until server takeover is accepted on
            // a physical device. Without this fallback, iOS can suspend the
            // app before the phone lease expires and the Live Activity stops
            // receiving local updates.
            if localSessionEnabled && localSessionActive && lockScreenLyricsEnabled {
                provider?.kick()
                // Start the keep-alive in the scene transition. Waiting for
                // the 250 ms ticker can allow iOS to suspend the process first.
                manageKeepAlive()
            }
            break
        default:
            break
        }
    }

    func startDemo() {
        guard !demoActive else { return }
        demoActive = true
        let lines = [
            "This is a demo lyric line",
            "It shows up on your Lock Screen",
            "And inside the Dynamic Island",
            "Synced line by line",
            "OpenLyrics",
        ]
        let track = TrackSignature(title: "Demo Song", artist: "OpenLyrics")
        let doc = LyricsDocument(
            track: track,
            lines: lines.enumerated().map { LyricLine(time: Double($0.offset) * 2.5, text: $0.element) }
        )
        lyrics.loadForDemo(doc)
        signature = track
        status = PlaybackStatus(state: .playing, position: 0, rate: 1, timestamp: .now)
    }

    func stopDemo() {
        demoActive = false
        localSessionActive = false
        signature = nil
        status = nil
        lyrics.update(signature: nil, status: nil)
        nowPlaying.clear()
        liveActivity.end()
        keeper.stop()
    }

    private func startPolling() {
        if provider == nil {
            provider = SpotifyProvider(auth: auth)
        }
        updatePollingProfile()
        provider?.start()
    }

    private func updatePollingProfile() {
        provider?.setAggressiveBackgroundMode(
            localSessionEnabled
                && localSessionActive
                && lockScreenLyricsEnabled
                && scenePhase != .active
        )
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.tick() }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var tickCount = 0

    private func tick() {
        // Heartbeat (throttled to ~5s): proves whether the process is alive &
        // polling while backgrounded/locked. Gaps in timestamps = suspended.
        tickCount += 1
        if tickCount % 20 == 0 {
            DiagnosticsLog.append("hb \(String(format: "%.1f", lyrics.displayPosition))s doc=\(lyrics.document != nil) la=\(liveActivity.isRunning)")
        }
        consumeLocalSessionRequest()
        if let provider {
            if provider.signature != signature {
                signature = provider.signature
                lastLineIndex = nil
            }
            if provider.status != status {
                status = provider.status
                // Real player state just landed; retire any optimistic
                // play/pause flip written by a widget button.
                SharedNowPlaying.setPlayingOverride(nil)
            }
            lyrics.update(
                signature: signature,
                trackID: provider.lastTrackID,
                status: status
            )
        } else if demoActive {
            lyrics.update(signature: signature, status: status)
        }

        prefetchAlbumArtworkIfNeeded()
        lyrics.tick()
        markRecoveredIfSilenceBroken()
        revivePollerIfNeeded()
        manageKeepAlive()
        publishNowPlayingIfDue()
        syncLiveActivity()
        syncServerHeartbeat()
        syncWidgetSnapshot()
        syncWatchSnapshot()
        consumeWidgetCommand()
    }

    /// Keeps the app alive while an explicit local lyric session owns a Live
    /// Activity. This is a beta device-testing path. The server remains the
    /// recovery authority when this setting is disabled.
    static let pausedKeepAliveLimit: TimeInterval = 600
    @ObservationIgnored private var lastPlayingAt = Date.distantPast

    private func manageKeepAlive() {
        guard localSessionEnabled && localSessionActive else {
            keeper.stop()
            return
        }
        if status?.state == .playing {
            lastPlayingAt = .now
        }

        guard scenePhase != .active else {
            keeper.stop()
            return
        }

        let withinPauseGrace = status?.state == .paused
            && Date.now.timeIntervalSince(lastPlayingAt) < Self.pausedKeepAliveLimit
        let shouldRun = (auth.isConnected || demoActive)
            && lockScreenLyricsEnabled
            && !liveActivity.wasDismissed
            && (status?.state == .playing || withinPauseGrace)

        if shouldRun {
            keeper.start()
            if !keeper.isPlayerAlive {
                keeper.resurrect()
            }
            keeper.setLoud(status?.state == .playing)
        } else {
            keeper.stop()
        }
    }

    /// Consumes a request written by the iOS 18 Control Center control or a
    /// Shortcuts automation. The request also enables the explicit beta
    /// setting because the user initiated it from a system control.
    private func consumeLocalSessionRequest() {
        guard SharedNowPlaying.consumeLocalSessionStartRequest() else { return }
        localSessionEnabled = true
        localSessionActive = true
        DiagnosticsLog.append("local session requested by control or shortcut")
    }

    private func syncServerHeartbeat() {
        guard auth.isConnected, let provider else { return }
        // Lease ownership follows the local poll loop, not the last successful
        // Spotify response. A temporary Spotify or network failure must not
        // make the server race the phone while the phone can still render its
        // already-loaded lyric schedule.
        let healthy = provider.isLoopLikelyAlive
        SyncServerClient.shared.heartbeat(
            activityState: liveActivity.syncActivityState,
            trackID: provider.lastTrackID,
            lyricOffset: lyrics.userOffset,
            localRevision: localLARevision,
            healthy: healthy,
            autoStartEnabled: lockScreenLyricsEnabled,
            albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] }
        )
    }

    /// A successful poll after >20s of silence means the feed just recovered
    /// (stall, network blip). Flush the card this tick even if nothing else
    /// changed, so the stale dim + ↻ clear immediately.
    @ObservationIgnored private var lastSeenPollSuccess: Date?
    private func markRecoveredIfSilenceBroken() {
        guard let provider else { return }
        defer { lastSeenPollSuccess = provider.lastSuccessfulPollAt }
        guard let current = provider.lastSuccessfulPollAt,
              let previous = lastSeenPollSuccess,
              current != previous else { return }
        let gap = Date.now.timeIntervalSince(previous)
        if gap > 20 {
            DiagnosticsLog.append("poll silence broken after \(Int(gap))s — forcing LA un-dim")
            lastLAUpdateAt = .distantPast
        }
    }

    /// Picks up play/pause + refresh requests made from widgets / Live Activity buttons.
    private func consumeWidgetCommand() {
        guard let envelope = PlaybackCommandBus.consumeEnvelope() else { return }
        DiagnosticsLog.append("cmd bus: \(envelope.command.rawValue) id=\(envelope.id.uuidString.prefix(8))")
        Task { [weak self] in
            guard let self else { return }

            // The running app is the lowest-latency Spotify client. Use it as
            // the command owner while its poller is alive. Sending the same
            // command to the server first adds a network round trip and can
            // make the Live Activity appear one or two seconds behind the
            // widget. The server remains the fallback when the app is not
            // polling (for example after termination).
            if envelope.command != .refresh,
               let localProvider = self.provider,
               localProvider.isPolling {
                let accepted: Bool
                switch envelope.command {
                case .togglePlayPause:
                    if let current = localProvider.status {
                        SharedNowPlaying.setPlayingOverride(current.state != .playing)
                    }
                    accepted = await localProvider.togglePlayPause()
                case .next:
                    accepted = await localProvider.next()
                case .previous:
                    accepted = await localProvider.previous()
                case .refresh:
                    accepted = true
                }
                if !accepted, envelope.command == .togglePlayPause {
                    SharedNowPlaying.setPlayingOverride(nil)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                return
            }

            if envelope.command != .refresh {
                switch await SyncServerClient.shared.sendCommand(envelope.command, id: envelope.id) {
                case .accepted:
                    provider?.kick()
                    provider?.burst()
                    return
                case .indeterminate, .rejected:
                    // Do not issue a second command. A lost response can mean
                    // that the server already performed the command.
                    provider?.kick()
                    provider?.burst(count: 8)
                    return
                case .unavailable:
                    break
                }
            }

            switch envelope.command {
            case .togglePlayPause:
                let accepted = await provider?.togglePlayPause() ?? false
                if !accepted {
                    // The real state never changed; drop the optimistic flip.
                    SharedNowPlaying.setPlayingOverride(nil)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            case .next:
                _ = await provider?.next()
            case .previous:
                _ = await provider?.previous()
            case .refresh:
                DiagnosticsLog.append("cmd: refresh")
                provider?.kick()
                provider?.burst(count: 8)
            }
        }
    }

    private func syncWidgetSnapshot() {
        // Track changed but the new song's lyrics haven't loaded yet: publish an
        // interim snapshot for the NEW track so widgets don't keep rendering the
        // previous song's timeline until WidgetKit's reload budget allows an
        // update. The full snapshot with scheduled lines follows once lyrics land.
        if let signature,
           status?.state == .playing,
           lyrics.document?.track != signature {
            let artworkURL = provider?.lastAlbumImageURL
            let artworkReady = artworkURL == nil || SharedNowPlaying.cachedArtwork(for: artworkURL) != nil
            let key = "interim|\(signature.title)|\(signature.artist)|\(artworkURL ?? "")|\(artworkReady)"
            guard key != lastPublishedWidgetKey else { return }
            lastPublishedWidgetKey = key
            widgetIdlePublished = false
            SharedNowPlaying.save(
                WidgetLyricSnapshot(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: artworkURL,
                    artworkKey: artworkURL.map(SharedNowPlaying.artworkKey),
                    albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                    trackID: provider?.lastTrackID,
                    trackDuration: signature.duration,
                    playbackEndEpoch: playbackEndEpoch(for: signature, at: .now),
                    currentLine: lyrics.isLoading ? "Loading lyrics…" : "♪",
                    isPlaying: true
                )
            )
            if artworkReady { reloadWidgetTimelines() }
            return
        }

        switch status?.state {
        case .stopped, .none:
            // One transient Spotify 204 is not a confirmed stop. Preserve the
            // last complete snapshot so the widget does not briefly lose its
            // artwork or fall back to the music-note placeholder during a
            // track transition or network gap.
            if status?.state == .stopped,
               provider?.isPlaybackConfirmedStopped != true {
                return
            }
            clearWidgetSnapshot()
            return
        case .paused:
            if widgetPausedAt == nil { widgetPausedAt = .now }
            if Date.now.timeIntervalSince(widgetPausedAt ?? .now) > Self.liveActivityPauseGrace {
                clearWidgetSnapshot()
                return
            }
        case .playing:
            widgetPausedAt = nil
        }

        guard let signature, let document = lyrics.document else {
            clearWidgetSnapshot()
            return
        }

        let isPlaying = status?.state == .playing
        let index = lyrics.currentIndex ?? -1
        let offsetKey = String(format: "%.3f", lyrics.userOffset)
        let artworkURL = provider?.lastAlbumImageURL
        let artworkReady = artworkURL == nil || SharedNowPlaying.cachedArtwork(for: artworkURL) != nil
        let now = Date.now
        let scheduled = scheduledLines(
            for: document,
            limit: Self.widgetScheduleMaxLines,
            horizon: Self.widgetScheduleHorizon
        )
        let currentPosition = status?.position(at: now) ?? lyrics.displayPosition
        let expectedPosition = lastWidgetPublishedPosition.map { position in
            position + now.timeIntervalSince(lastWidgetPublishedAt ?? now) * lastWidgetPublishedRate
        }
        // A seek can leave the active lyric unchanged. Publish one corrected
        // schedule when the playback clock moves by more than 750 ms from the
        // last published clock. Ordinary clock advancement must not rewrite the
        // app-group snapshot every tick.
        let seekCorrection = expectedPosition.map {
            abs(currentPosition - $0) > 0.75
        } ?? false
        let correctionKey = seekCorrection
            ? String(format: "seek=%.1f", currentPosition)
            : "steady"
        let key = "\(signature.title)|\(signature.artist)|\(index)|\(isPlaying)|\(document.lines.count)|\(offsetKey)|\(artworkURL ?? "")|\(artworkReady)|\(correctionKey)"
        guard key != lastPublishedWidgetKey else { return }
        lastPublishedWidgetKey = key
        widgetIdlePublished = false

        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        SharedNowPlaying.save(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: artworkURL,
                artworkKey: artworkURL.map(SharedNowPlaying.artworkKey),
                albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                trackID: provider?.lastTrackID,
                trackDuration: signature.duration,
                playbackEndEpoch: playbackEndEpoch(for: signature, at: now),
                currentLine: current,
                isPlaying: isPlaying,
                updatedAt: .now,
                scheduledLines: scheduled
            )
        )
        lastWidgetPublishedPosition = currentPosition
        lastWidgetPublishedAt = now
        lastWidgetPublishedRate = isPlaying ? max(status?.rate ?? 1, 0.001) : 0
        // Reload WidgetKit ONLY on meaningful changes (track, lyrics arriving,
        // play state). The daily reload budget cannot sustain per-line reloads;
        // between reloads the widget steps through its precomputed timeline
        // locally without talking to us.
        let reloadKey = "\(signature.title)|\(signature.artist)|\(isPlaying)|\(scheduled.isEmpty ? "nosched" : "sched")|\(artworkURL ?? "")|\(artworkReady)"
        if reloadKey != lastReloadedWidgetKey {
            lastReloadedWidgetKey = reloadKey
            reloadWidgetTimelines()
        }
    }

    @ObservationIgnored private var lastReloadedWidgetKey: String?

    /// Downloads the current album image in the app process and stores a
    /// reduced copy in the shared app group. Extensions can then render the
    /// image without depending on a network request during a timeline refresh.
    private func prefetchAlbumArtworkIfNeeded() {
        guard let urlString = provider?.lastAlbumImageURL else { return }
        guard SharedNowPlaying.cachedArtwork(for: urlString) == nil else { return }

        let now = Date.now
        if urlString == lastArtworkPrefetchURL,
           now.timeIntervalSince(lastArtworkPrefetchAt ?? .distantPast) < 30 {
            return
        }
        lastArtworkPrefetchURL = urlString
        lastArtworkPrefetchAt = now
        albumArtworkPrefetchTask?.cancel()
        albumArtworkPrefetchTask = Task { [weak self] in
            let fetched = await AlbumArtworkPrefetcher.fetch(urlString: urlString)
            guard !Task.isCancelled else { return }
            guard let data = fetched else {
                DiagnosticsLog.append("art cache: fetch failed")
                return
            }
            await ArtworkRepository.shared.save(data, for: urlString)
            DiagnosticsLog.append("art cache: stored \(data.count) bytes")
            guard let self, self.provider?.lastAlbumImageURL == urlString else { return }
            self.lastPublishedWidgetKey = nil
            self.lastReloadedWidgetKey = nil
            self.lastLAArtworkReady = nil
            self.syncWidgetSnapshot()
        }
    }

    private func reloadWidgetTimelines() {
        // All styles use the same shared snapshot. Reload each kind when the
        // track or artwork changes, otherwise a newly added style can keep the
        // previous track until WidgetKit performs an unrelated refresh.
        let kinds = [
            "CurrentLineWidget",
            "AlbumPlayerWidget",
            "LyricFocusWidget",
            "MinimalLyricsWidget",
            "AlbumCardWidget",
            "KaraokeFocusWidget",
            "LyricsPosterWidget",
            "WaveformPlayerWidget",
            "AlbumStackWidget",
            "LockscreenLyricWidget",
            "LockscreenAlbumWidget",
            "LockscreenQuoteWidget",
            "VinylWidget",
        ]
        for kind in kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    private func clearWidgetSnapshot() {
        guard !widgetIdlePublished else { return }
        widgetIdlePublished = true
        lastPublishedWidgetKey = nil
        lastWidgetPublishedPosition = nil
        lastWidgetPublishedAt = nil
        lastWidgetPublishedRate = 1
        SharedNowPlaying.clear()
        reloadWidgetTimelines()
        watchSync.clear()
    }

    /// Mirrors the complete widget snapshot to a paired Apple Watch. The watch
    /// stores it in its own app group so complications can advance locally.
    private func syncWatchSnapshot() {
        guard let signature, let document = lyrics.document, status?.state != .stopped else {
            return
        }
        if status?.state == .paused,
           let pauseDate = widgetPausedAt,
           Date.now.timeIntervalSince(pauseDate) > Self.liveActivityPauseGrace {
            return
        }
        let index = lyrics.currentIndex ?? -1
        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        let artworkURL = provider?.lastAlbumImageURL
        watchSync.publish(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: artworkURL,
                artworkKey: artworkURL.map(SharedNowPlaying.artworkKey),
                albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                trackID: provider?.lastTrackID,
                trackDuration: signature.duration,
                playbackEndEpoch: playbackEndEpoch(for: signature, at: .now),
                currentLine: current,
                isPlaying: status?.state == .playing,
                scheduledLines: scheduledLines(
                    for: document,
                    limit: Self.watchScheduleMaxLines,
                    horizon: Self.watchScheduleHorizon
                )
            )
        )
    }

    /// Status says playing but data went quiet: something killed polling
    /// (revoked audio session, hung socket). Revive only when the loop is
    /// genuinely dead/hung — restarting a live loop cancels its in-flight
    /// request and, at tick frequency, starves recovery forever.
    @ObservationIgnored private var lastReviveAt: Date?
    private func revivePollerIfNeeded() {
        guard status?.state == .playing, let provider else { return }
        guard provider.isPolling else { return } // signed out: stay stopped
        guard !provider.isLoopLikelyAlive else { return }
        guard let last = provider.lastSuccessfulPollAt,
              Date.now.timeIntervalSince(last) > 8 else { return }
        if let lastRevive = lastReviveAt,
           Date.now.timeIntervalSince(lastRevive) < 3 { return }
        lastReviveAt = .now
        DiagnosticsLog.append("watchdog: revive")
        provider.kick()
    }

    @ObservationIgnored private var lastPublishedNowPlaying: String?

    /// Mirrors playback into MPNowPlayingInfoCenter (throttled to 2s) so the
    /// system routes lock-screen transport events to us.
    private func publishNowPlayingIfDue() {
        guard let signature, status?.state != .stopped else {
            nowPlaying.clear()
            return
        }
        let state = status?.state
        let key = "\(signature.title)|\(state == .playing)"
        let now = Date.now
        let due = key != lastPublishedNowPlaying
            || now.timeIntervalSince(lastNowPlayingPublishAt ?? .distantPast) >= 2
        guard due else { return }
        lastPublishedNowPlaying = key
        lastNowPlayingPublishAt = now
        nowPlaying.publish(
            signature: signature,
            position: status?.position(at: now) ?? 0,
            duration: signature.duration,
            rate: state == .playing ? (status?.rate ?? 1) : 0
        )
    }
    @ObservationIgnored private var lastNowPlayingPublishAt: Date?

    private func syncLiveActivity() {
        guard lockScreenLyricsEnabled, auth.isConnected || demoActive else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }

        switch status?.state {
        case .stopped:
            // SpotifyProvider requires two independent stopped samples before
            // it clears the active item. Keep the Activity through one 204 so
            // skip transitions and network gaps do not remove artwork.
            if provider?.isPlaybackConfirmedStopped == true {
                if liveActivity.isRunning { liveActivity.end() }
                liveActivity.resetDismissalForNewPlaybackSession()
                SyncServerClient.shared.resetDismissalForNewSession()
                stoppedAt = nil
                pausedAt = nil
            } else if stoppedAt == nil {
                stoppedAt = .now
            }
            return
        case .none:
            // Do not treat app startup as a confirmed Spotify stop. The first
            // successful player response determines the playback session.
            return
        case .paused:
            stoppedAt = nil
            if pausedAt == nil { pausedAt = .now }
            if Date.now.timeIntervalSince(pausedAt ?? .now) > Self.liveActivityPauseGrace {
                if liveActivity.isRunning { liveActivity.end() }
                return
            }
        case .playing:
            if let pausedAt, Date.now.timeIntervalSince(pausedAt) >= Self.liveActivityPauseGrace {
                liveActivity.resetDismissalForNewPlaybackSession()
                SyncServerClient.shared.resetDismissalForNewSession()
            }
            pausedAt = nil
            stoppedAt = nil
        }

        if SyncServerClient.shared.serverSessionDismissed {
            liveActivity.suppressForCurrentPlaybackSession()
            return
        }

        let style = loadLAStyle()
        let styleKey = "\(style.prefs.theme.rawValue)|\(style.prefs.layout.rawValue)|\(style.prefs.artworkStyle.rawValue)|\(style.prefs.surfaceStyle.rawValue)|\(style.prefs.textAlignment.rawValue)|\(style.prefs.fontStyle.rawValue)|\(style.prefs.lyricScale.rawValue)|\(style.prefs.showTrackInfo)|\(style.prefs.showControls)|\(style.prefs.showNextLine)|\(style.prefs.showProgressBar)|\(style.prefs.animationsEnabled)|\(style.prefs.karaokeEnabled)"

        guard let signature else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }
        let artworkURL = provider?.lastAlbumImageURL
        let artworkReady = artworkURL == nil || SharedNowPlaying.cachedArtwork(for: artworkURL) != nil
        // Publish the new track before the lyrics request completes. Waiting
        // for LRCLIB here leaves the old card or music-note placeholder visible
        // during the whole network lookup.
        guard let document = lyrics.document else {
            // Update the placeholder at most once per state change. ActivityKit
            // rate-limits repeated updates, and the app tick runs four times a
            // second.
            let placeholderKey = "\(provider?.lastTrackID ?? "-")|\(signature.title)|\(signature.artist)|\(provider?.lastAlbumImageURL ?? "-")|\(status?.state == .playing)|\(lyrics.isAwaitingLyrics)|\(artworkReady)|\(styleKey)|\(String(format: "%.3f", lyrics.userOffset))"
            let anchors = status.map { PlaybackAnchors(status: $0, duration: signature.duration) }
            let placeholderState: LyricsActivityAttributes.ContentState = stamped({
                LyricsActivityAttributes.ContentState(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: provider?.lastAlbumImageURL,
                    currentLine: lyrics.isAwaitingLyrics ? "Finding lyrics…" : "No lyrics for this track",
                    isPlaying: status?.state == .playing,
                    frozenProgress: anchors?.frozenFraction,
                    albumDominantRGB: style.prefs.theme == .album
                        ? style.accent.map { [$0.r, $0.g, $0.b] } : nil,
                    schemaVersion: 2,
                    source: .phone,
                    trackID: provider?.lastTrackID,
                    progressStartEpoch: anchors?.startDate.timeIntervalSince1970,
                    progressEndEpoch: anchors?.endDate?.timeIntervalSince1970
                )
            }())

            var startedNow = false
            if !liveActivity.isRunning {
                let now = Date.now
                guard now.timeIntervalSince(lastLAStartAttemptAt ?? .distantPast) >= 1 else { return }
                lastLAStartAttemptAt = now
                liveActivity.start(state: placeholderState)
                guard liveActivity.isRunning else { return }
                startedNow = true
            }

            let placeholderAnchorChanged: Bool = {
                switch (
                    lastAppliedLAProgressStartEpoch,
                    placeholderState.progressStartEpoch
                ) {
                case let (old?, new?): abs(old - new) > 0.75
                case (.none, .none): false
                default: true
                }
            }()
            if placeholderKey != lastLAPlaceholderKey || placeholderAnchorChanged {
                lastLAPlaceholderKey = placeholderKey
                // `start` already delivered this exact state. Avoid an
                // immediate second ActivityKit call on a fresh activity.
                if !startedNow {
                    liveActivity.update(state: placeholderState, priority: .high)
                }
                lastLineIndex = nil
                lastLAUpdateAt = .now
                lastLASentIsPlaying = placeholderState.isPlaying
                lastLASentTrack = "\(placeholderState.trackID ?? "-")|\(placeholderState.trackTitle)|\(placeholderState.artistName)|\(placeholderState.albumImageURL ?? "-")|placeholder"
                lastSentLAHash = laContentHash(placeholderState)
                lastLAArtworkReady = artworkReady
                lastAppliedStyleKey = styleKey
                lastSentAccent = placeholderState.albumDominantRGB
                lastSentLASchedule = []
                lastAppliedLAOffset = lyrics.userOffset
                lastAppliedLAProgressStartEpoch = placeholderState.progressStartEpoch
            }
            return
        }

        lastLAPlaceholderKey = nil
        if !liveActivity.isRunning {
            // Recovery: try adoption AND fresh creation on every tick. iOS
            // rejects what isn't allowed (background creation); attempting is
            // free and self-heals faster than gating on scenePhase guesses.
            let startState = stamped(contentState(document: document, style: style.prefs, albumAccent: style.accent))
            let now = Date.now
            guard now.timeIntervalSince(lastLAStartAttemptAt ?? .distantPast) >= 1 else { return }
            lastLAStartAttemptAt = now
            liveActivity.start(state: startState)
            lastLineIndex = lyrics.currentIndex
            lastLAUpdateAt = .now
            lastLASentIsPlaying = startState.isPlaying
            lastLASentTrack = "\(startState.trackID ?? "-")|\(startState.trackTitle)|\(startState.artistName)|\(startState.albumImageURL ?? "-")|\(document.lines.count)"
            lastLAArtworkReady = artworkReady
            lastSentLAHash = laContentHash(startState)
            lastAppliedStyleKey = styleKey
            lastSentAccent = startState.albumDominantRGB
            lastAppliedLAOffset = lyrics.userOffset
            lastSentLASchedule = startState.resolvedScheduledLines
            lastAppliedLAProgressStartEpoch = startState.progressStartEpoch
            return
        }

        // Update diet + honest staleness: send when content the user READS
        // changes (line, track, play state, style/accent), plus a slow
        // keep-alive pulse so the card's staleDate never expires mid-gap —
        // otherwise lyric gaps fake-stale the card and ↻ stops meaning
        // anything. The progress bar advances itself via TimelineView on the
        // widget's own clock.
        let targetState = contentState(document: document, style: style.prefs, albumAccent: style.accent)
        let trackKey = "\(targetState.trackID ?? "-")|\(targetState.trackTitle)|\(targetState.artistName)|\(targetState.albumImageURL ?? "-")|\(document.lines.count)"
        let trackChanged = trackKey != lastLASentTrack
        let lineChanged = lyrics.currentIndex != lastLineIndex
        let playChanged = targetState.isPlaying != lastLASentIsPlaying
        let artworkChanged = artworkReady != lastLAArtworkReady
        let now = Date.now
        // A style or album-color change re-renders immediately so in-app
        // appearance picks land within one tick.
        let accentChanged = targetState.albumDominantRGB != lastSentAccent
        let styleChanged = styleKey != lastAppliedStyleKey
        let offsetChanged = lastAppliedLAOffset.map {
            abs($0 - lyrics.userOffset) > 0.001
        } ?? false
        let anchorChanged: Bool = {
            switch (lastAppliedLAProgressStartEpoch, targetState.progressStartEpoch) {
            case let (old?, new?): abs(old - new) > 0.75
            case (.none, .none): false
            default: true
            }
        }()
        let urgent = trackChanged || playChanged || artworkChanged || accentChanged
            || styleChanged || offsetChanged || anchorChanged
        let sinceLastSend = now.timeIntervalSince(lastLAUpdateAt ?? .distantPast)
        let remainingSchedule = lastSentLASchedule.filter { $0.date > now }
        let targetSchedule = targetState.resolvedScheduledLines
        let currentEnd = remainingSchedule.last?.date ?? .distantPast
        let targetEnd = targetSchedule.last?.date ?? .distantPast
        let canExtendSchedule = targetEnd.timeIntervalSince(currentEnd) > 1
        let scheduleLow = remainingSchedule.count < 3
            || currentEnd.timeIntervalSince(now) < 20
        let scheduleRefill = targetState.isPlaying && scheduleLow
            && canExtendSchedule
            && sinceLastSend >= Self.minimumScheduleRefillInterval

        // A valid schedule changes the lyric inside the extension. A direct
        // line update is only a fallback for tracks without future boundaries.
        let minGapPassed = sinceLastSend >= 0.5
        let lineSend = lineChanged && targetSchedule.isEmpty
            && minGapPassed && !throttleCapped(now: now)
        let keepAliveSend = status?.state == .playing
            && targetSchedule.isEmpty
            && !urgent
            && sinceLastSend >= 45
        // Reconciliation self-heal: ActivityKit silently drops background
        // updates now and then. If what we last sent differs from current
        // truth for >45s, resend. Generous window — frequent reconciles were
        // part of the update spam that invited throttling in the first place.
        let reconciling = sinceLastSend >= 60
            && lastSentLAHash != nil
            && lastSentLAHash != laContentHash(targetState)
        if reconciling && !(urgent || scheduleRefill || lineSend || keepAliveSend) {
            DiagnosticsLog.append("la reconcile: resending drifted state")
        }
        if scheduleRefill {
            DiagnosticsLog.append("la schedule refill: remaining=\(remainingSchedule.count)")
        }
        if urgent || scheduleRefill || lineSend || keepAliveSend || reconciling {
            if urgent {
                liveActivity.interruptPendingUpdates(reason: "material playback change")
            }
            let sentState = stamped(targetState)
            liveActivity.update(
                state: sentState,
                priority: urgent ? .high : .low
            )
            lastLAUpdateAt = now
            lastLineIndex = lyrics.currentIndex
            lastLASentIsPlaying = sentState.isPlaying
            lastLASentTrack = trackKey
            lastLAArtworkReady = artworkReady
            lastSentLAHash = laContentHash(sentState)
            lastAppliedStyleKey = styleKey
            lastSentAccent = sentState.albumDominantRGB
            lastAppliedLAOffset = lyrics.userOffset
            lastSentLASchedule = sentState.resolvedScheduledLines
            lastAppliedLAProgressStartEpoch = sentState.progressStartEpoch
            recordLASendRate()
        }
    }

    // MARK: LA update-rate telemetry + hard throttle cap

    @ObservationIgnored private var recentLASends: [Date] = []
    @ObservationIgnored private var lastRateWarningAt: Date?

    /// Warns when we approach ActivityKit's throttling territory — every past
    /// "frozen card" investigation has ended at this cliff.
    private func recordLASendRate() {
        let now = Date.now
        recentLASends.append(now)
        recentLASends.removeAll { now.timeIntervalSince($0) > 60 }
        if recentLASends.count > 16,
           now.timeIntervalSince(lastRateWarningAt ?? .distantPast) > 60 {
            lastRateWarningAt = now
            DiagnosticsLog.append("la rate warning: \(recentLASends.count) sends/min — throttle risk")
        }
    }

    /// Soft app-side cap: skip storms and dense lyrics cannot park the
    /// activity. ActivityKit still owns the final device-level budget.
    private func throttleCapped(now: Date) -> Bool {
        recentLASends.removeAll { now.timeIntervalSince($0) > 60 }
        return recentLASends.count >= 20
    }

    @ObservationIgnored private var lastLAPlaceholderKey: String?
    @ObservationIgnored private var lastLAUpdateAt: Date?
    @ObservationIgnored private var lastLAArtworkReady: Bool?
    /// Hash of the last ContentState we actually handed to ActivityKit —
    /// compared against current truth by the reconciliation self-heal.
    @ObservationIgnored private var lastSentLAHash: String?
    /// Style prefs as of the last LA render — a mismatch forces an immediate
    /// re-render so in-app appearance changes land on the activity instantly.
    @ObservationIgnored private var lastAppliedStyleKey: String?
    /// User lyric offset as of the last Live Activity schedule refresh.
    @ObservationIgnored private var lastAppliedLAOffset: TimeInterval?
    /// Extracted album dominant color (Album mode) + the artwork URL it came from.
    @ObservationIgnored private var albumAccent: RGB?
    @ObservationIgnored private var albumAccentForURL: String?
    @ObservationIgnored private var albumAccentTask: Task<Void, Never>?
    @ObservationIgnored private var albumAccentGeneration = 0
    @ObservationIgnored private var lastSentAccent: [Double]?
    @ObservationIgnored private var lastSentLASchedule: [WidgetLyricSnapshot.ScheduledLine] = []
    @ObservationIgnored private var lastAppliedLAProgressStartEpoch: TimeInterval?
    @ObservationIgnored private var localLARevision: Int64 = 0
    /// Starting an Activity can fail while iOS is changing scene state. Do not
    /// retry on every 250 ms model tick because that can create a start storm.
    @ObservationIgnored private var lastLAStartAttemptAt: Date?
    /// A paused Activity is useful for a short break, but it must not remain
    /// on the Lock Screen after the user has stopped listening.
    private static let liveActivityPauseGrace: TimeInterval = 600
    private static let lyricScheduleHorizon: TimeInterval = 75
    private static let lyricScheduleMaxLines = 32
    /// WidgetKit can render a larger local timeline than ActivityKit can
    /// accept in one content state. Keep the full song schedule here so a
    /// suspended app does not leave widgets on the last few lyric lines.
    private static let widgetScheduleHorizon: TimeInterval = 4 * 60 * 60
    private static let widgetScheduleMaxLines = 512
    private static let watchScheduleHorizon: TimeInterval = 4 * 60 * 60
    private static let watchScheduleMaxLines = 128
    private static let minimumScheduleRefillInterval: TimeInterval = 15

    /// Stable fingerprint of a ContentState. Anchor dates are second-rounded:
    /// during steady playback startDate/endDate are constant anyway, so any
    /// hash drift means real content (title, line, play state, bar) moved.
    private func laContentHash(_ s: LyricsActivityAttributes.ContentState) -> String {
        "\(s.trackTitle)|\(s.artistName)|\(s.albumImageURL ?? "-")|\(s.currentLine)|\(s.nextLine ?? "-")|\(s.isPlaying)"
            + "|\(s.resolvedProgressStart.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.resolvedProgressEnd.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.frozenProgress.map { Int(($0 * 100).rounded()) } ?? -1)"
            + "|\(s.resolvedKaraokeStart.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.resolvedKaraokeEnd.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.frozenKaraokeProgress.map { Int(($0 * 100).rounded()) } ?? -1)"
            + "|\(s.albumDominantRGB.map { $0.map { Int($0 * 255) } } ?? [])"
    }

    /// Loads current appearance prefs and keeps the album dominant color fresh
    /// when Album mode is active. Called once per tick before LA work.
    private func loadLAStyle() -> (prefs: LAStylePrefs, accent: RGB?) {
        let prefs = LAStyleStore.load()
        guard prefs.theme == .album, let art = provider?.lastAlbumImageURL else {
            albumAccentTask?.cancel()
            albumAccentTask = nil
            albumAccentGeneration += 1
            albumAccentForURL = nil
            albumAccent = nil
            return (prefs, nil)
        }
        if art != albumAccentForURL {
            albumAccentTask?.cancel()
            albumAccentGeneration += 1
            let generation = albumAccentGeneration
            albumAccentForURL = art
            // Clear the old color immediately. A slow request for the previous
            // track must never tint the new track.
            albumAccent = DominantColorExtractor.cached(for: art)
            albumAccentTask = Task { [weak self] in
                let color = await DominantColorExtractor.extract(from: art)
                guard !Task.isCancelled, let self,
                      self.albumAccentGeneration == generation,
                      self.albumAccentForURL == art else { return }
                self.albumAccent = color
                DiagnosticsLog.append("album accent extracted for current artwork")
            }
        }
        return (prefs, albumAccent)
    }
    private var scenePhase: ScenePhase = .inactive
    @ObservationIgnored private var lastLASentIsPlaying = false
    @ObservationIgnored private var lastLASentTrack: String?
    private func contentState(document: LyricsDocument,
                              style: LAStylePrefs,
                              albumAccent: RGB?) -> LyricsActivityAttributes.ContentState {
        let index = lyrics.currentIndex
        let current = index.map { document.lines[$0].text } ?? "♪"
        let next = index.map { $0 + 1 < document.lines.count ? document.lines[$0 + 1].text : nil } ?? nil
        let anchors = status.map { PlaybackAnchors(status: $0, duration: signature?.duration) }
        let karaoke = karaokeTiming(for: document)
        let dominant: [Double]? = style.theme == .album
            ? albumAccent.map { [$0.r, $0.g, $0.b] }
            : nil
        // Start with a generous window, then trim by encoded byte size before
        // handing the state to ActivityKit.
        // Send one bounded look-ahead batch. The renderers advance at the
        // exact onset dates, so a line does not need its own ActivityKit push.
        let scheduled = scheduledLines(for: document, limit: Self.lyricScheduleMaxLines).map {
            ActivityScheduledLine(
                dateEpoch: $0.date.timeIntervalSince1970,
                text: $0.text,
                endDateEpoch: $0.endDate?.timeIntervalSince1970
            )
        }
        return .init(
            trackTitle: signature?.title ?? document.track.title,
            artistName: signature?.artist ?? document.track.artist,
            albumImageURL: provider?.lastAlbumImageURL,
            currentLine: current,
            nextLine: next,
            isPlaying: status?.state == .playing,
            frozenProgress: anchors?.frozenFraction,
            frozenKaraokeProgress: karaoke.frozen,
            albumDominantRGB: dominant,
            schemaVersion: 2,
            source: .phone,
            trackID: provider?.lastTrackID,
            progressStartEpoch: anchors?.startDate.timeIntervalSince1970,
            progressEndEpoch: anchors?.endDate?.timeIntervalSince1970,
            scheduledLinesV2: scheduled.isEmpty ? nil : scheduled,
            karaokeStartEpoch: karaoke.start?.timeIntervalSince1970,
            karaokeEndEpoch: karaoke.end?.timeIntervalSince1970
        )
    }

    private func stamped(
        _ state: LyricsActivityAttributes.ContentState
    ) -> LyricsActivityAttributes.ContentState {
        localLARevision += 1
        var copy = state
        copy.schemaVersion = 2
        copy.source = .phone
        copy.revision = localLARevision
        copy.generatedAtEpoch = Date.now.timeIntervalSince1970
        let compact = copy.compacted()
        if compact.encodedSize > 3_500 {
            DiagnosticsLog.append("la payload remains oversized: \(compact.encodedSize) bytes")
        }
        return compact
    }

    /// Maps the active LRC line onto the same playback clock used by the main
    /// lyrics view. While playing, the extension receives a wall-clock
    /// interval; while paused, it receives a frozen fraction instead.
    private func karaokeTiming(for document: LyricsDocument)
        -> (start: Date?, end: Date?, frozen: Double?) {
        guard let index = lyrics.currentIndex,
              document.lines.indices.contains(index),
              let status else {
            return (nil, nil, nil)
        }

        let lineStart = document.lines[index].time + lyrics.userOffset
        let lineEnd = index + 1 < document.lines.count
            ? document.lines[index + 1].time + lyrics.userOffset
            : max(lineStart + 0.25, signature?.duration ?? lineStart + 4)
        let end = max(lineStart + 0.25, lineEnd)
        let position = lyrics.displayPosition
        let fraction = min(max((position - lineStart) / (end - lineStart), 0), 1)

        guard status.state == .playing else {
            return (nil, nil, fraction)
        }

        let rate = max(status.rate, 0.001)
        let now = Date.now
        return (
            now.addingTimeInterval((lineStart - position) / rate),
            now.addingTimeInterval((end - position) / rate),
            nil
        )
    }

    /// Converts the same playback position used by the in-app lyric scroller
    /// into absolute dates. Widgets, the watch complication, and the Live
    /// Activity can then advance independently without polling the app every
    /// frame or consuming ActivityKit's update budget.
    private func scheduledLines(for document: LyricsDocument,
                                limit: Int,
                                horizon: TimeInterval? = nil)
        -> [WidgetLyricSnapshot.ScheduledLine] {
        guard status?.state == .playing else { return [] }
        let now = Date.now
        let batch = LyricBatchBuilder.make(
            document: document,
            position: lyrics.displayPosition,
            offset: lyrics.userOffset,
            now: now,
            rate: status?.rate ?? 1,
            horizon: horizon ?? Self.lyricScheduleHorizon,
            maxLines: max(1, limit),
            trackID: provider?.lastTrackID
        )
        return batch.lines.map {
            .init(
                date: Date(timeIntervalSince1970: $0.startEpoch),
                text: $0.text,
                endDate: Date(timeIntervalSince1970: $0.endEpoch)
            )
        }
    }

    private func playbackEndEpoch(for signature: TrackSignature,
                                  at date: Date) -> TimeInterval? {
        guard status?.state == .playing,
              let duration = signature.duration,
              duration.isFinite,
              duration > 0 else { return nil }
        let position = max(0, status?.position(at: date) ?? lyrics.displayPosition)
        let rate = max(status?.rate ?? 1, 0.001)
        return date.timeIntervalSince1970 + max(0, duration - position) / rate
    }
}
