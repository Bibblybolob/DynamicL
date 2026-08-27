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
    private let keeper = BackgroundAudioKeeper.shared

    private var widgetPausedAt: Date?
    private var lastPublishedWidgetKey: String?
    private var widgetIdlePublished = false

    private(set) var demoActive = false

    var lockScreenLyricsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockScreenLyricsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "lockScreenLyricsEnabled")
            if !newValue {
                liveActivity.end()
                keeper.stop()
            }
        }
    }

    init() {
        startTicker()
        watchSync.activateIfNeeded()
        installNowPlayingBridge()
        if auth.isConnected {
            startPolling()
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
                Task {
                    let accepted = await self.provider?.togglePlayPause() ?? false
                    if accepted { self.provider?.burst() } else { SharedNowPlaying.setPlayingOverride(nil) }
                }
            },
            next: { [weak self] in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: next")
                Task { await provider.next() }
            },
            previous: { [weak self] in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: prev")
                Task { await provider.previous() }
            },
            changePosition: { [weak self] position in
                guard let self, let provider = self.provider else { return }
                DiagnosticsLog.append("cmd: seek \(Int(position))s")
                Task { await provider.seek(to: position) }
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
        } catch {
            connectError = error.localizedDescription
        }
    }

    func disconnect() {
        provider?.stop()
        provider = nil
        auth.disconnect()
        signature = nil
        status = nil
        lyrics.update(signature: nil, status: nil)
        nowPlaying.clear()
        liveActivity.end()
        keeper.stop()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            if auth.isConnected { startPolling() }
        case .background:
            // Deliberately do NOT stop the poller here. While the silent
            // keep-alive audio runs (playing + lock-screen toggle on), the tick
            // loop must keep polling so the Lock Screen Live Activity stays in
            // sync. When keep-alive doesn't apply, iOS suspends the process on
            // its own within seconds, which stops polling anyway.
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
        provider?.start()
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
            lyrics.update(signature: signature, status: status)
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
        syncWidgetSnapshot()
        syncWatchSnapshot()
        consumeWidgetCommand()
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
        switch PlaybackCommandBus.consume() {
        case .togglePlayPause:
            Task { [weak self] in
                guard let self else { return }
                let accepted = await provider?.togglePlayPause() ?? false
                if !accepted {
                    // The real state never changed; drop the optimistic flip.
                    SharedNowPlaying.setPlayingOverride(nil)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        case .next:
            Task { await provider?.next() }
        case .previous:
            Task { await provider?.previous() }
        case .refresh:
            DiagnosticsLog.append("cmd: refresh")
            provider?.kick()
            provider?.burst(count: 8)
        case nil:
            break
        }
    }

    private func syncWidgetSnapshot() {
        // Track changed but the new song's lyrics haven't loaded yet: publish an
        // interim snapshot for the NEW track so widgets don't keep rendering the
        // previous song's timeline until WidgetKit's reload budget allows an
        // update. The full snapshot with scheduled lines follows once lyrics land.
        if let signature, status?.state == .playing,
           lyrics.document == nil || lyrics.document?.track != signature {
            let artworkURL = provider?.lastAlbumImageURL
            let artworkData = SharedNowPlaying.cachedArtwork(for: artworkURL)
            let artworkReady = artworkURL == nil || artworkData != nil
            let key = "interim|\(signature.title)|\(signature.artist)|\(artworkURL ?? "")|\(artworkReady)"
            guard key != lastPublishedWidgetKey else { return }
            lastPublishedWidgetKey = key
            widgetIdlePublished = false
            SharedNowPlaying.save(
                WidgetLyricSnapshot(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: artworkURL,
                    albumImageData: artworkData,
                    currentLine: lyrics.isLoading ? "Loading lyrics…" : "♪",
                    isPlaying: true
                )
            )
            if artworkReady { reloadWidgetTimelines() }
            return
        }

        switch status?.state {
        case .stopped, .none:
            clearWidgetSnapshot()
            return
        case .paused:
            if widgetPausedAt == nil { widgetPausedAt = .now }
            if Date.now.timeIntervalSince(widgetPausedAt ?? .now) > 300 {
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
        let artworkData = SharedNowPlaying.cachedArtwork(for: artworkURL)
        let artworkReady = artworkURL == nil || artworkData != nil
        let key = "\(signature.title)|\(signature.artist)|\(index)|\(isPlaying)|\(document.lines.count)|\(offsetKey)|\(artworkURL ?? "")|\(artworkReady)"
        guard key != lastPublishedWidgetKey else { return }
        lastPublishedWidgetKey = key
        widgetIdlePublished = false

        let scheduled = scheduledLines(for: document, limit: 40)

        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        SharedNowPlaying.save(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: artworkURL,
                albumImageData: artworkData,
                currentLine: current,
                isPlaying: isPlaying,
                updatedAt: .now,
                scheduledLines: scheduled
            )
        )
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
            guard let data = await AlbumArtworkPrefetcher.fetch(urlString: urlString),
                  !Task.isCancelled else { return }
            SharedNowPlaying.saveArtwork(data, for: urlString)
            guard let self, self.provider?.lastAlbumImageURL == urlString else { return }
            self.lastPublishedWidgetKey = nil
            self.lastReloadedWidgetKey = nil
            self.lastLAArtworkReady = nil
            self.syncWidgetSnapshot()
        }
    }

    private func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: "CurrentLineWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "LockscreenLyricWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "VinylWidget")
    }

    private func clearWidgetSnapshot() {
        guard !widgetIdlePublished else { return }
        widgetIdlePublished = true
        lastPublishedWidgetKey = nil
        SharedNowPlaying.clear()
        reloadWidgetTimelines()
        watchSync.clear()
    }

    /// Mirrors the widget snapshot to a paired Apple Watch, deduped per line change.
    private func syncWatchSnapshot() {
        guard let signature, let document = lyrics.document, status?.state != .stopped else {
            return
        }
        let index = lyrics.currentIndex ?? -1
        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        watchSync.publish(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                currentLine: current,
                isPlaying: status?.state == .playing
            )
        )
    }

    /// How long a real pause keeps the process alive so an unpause is heard
    /// without unlocking. iOS suspends a released app within ~60s.
    static let pausedKeepAliveLimit: TimeInterval = 600
    @ObservationIgnored private var lastPlayingAt: Date = .distantPast

    private func manageKeepAlive() {
        // Session-wide persistence: the process must survive pauses (up to the
        // limit above), stale-API stalls, and playback — otherwise iOS suspends
        // it and resume events land unheard (tonight's 798s coma). Volume drops
        // to near-silence while idle instead of releasing the session.
        if status?.state == .playing { lastPlayingAt = .now }
        let now = Date.now
        let stalled = provider?.shouldHoldKeepAlive ?? false
        let withinPauseGrace = status?.state == .paused
            && now.timeIntervalSince(lastPlayingAt) < Self.pausedKeepAliveLimit
        let shouldRun = (auth.isConnected || demoActive)
            && lockScreenLyricsEnabled
            && (status?.state == .playing || withinPauseGrace || stalled)
        if shouldRun {
            keeper.start()
            // Self-heal: interruptions, route changes, or media-server resets
            // can stop audio while isKeepingAlive still reads true. Without
            // this guard the process gets suspended and everything freezes.
            if !keeper.isPlayerAlive {
                keeper.resurrect()
            }
        } else {
            keeper.stop()
        }
        keeper.setLoud(status?.state == .playing)
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
        case .stopped, .none:
            // Single stopped blips happen right after skips (204/no-device).
            // Require two consecutive observations before tearing the LA down.
            stoppedStreak += 1
            if stoppedStreak >= 2 {
                if liveActivity.isRunning { liveActivity.end() }
                pausedAt = nil
            }
            return
        case .paused:
            if pausedAt == nil { pausedAt = .now }
            if Date.now.timeIntervalSince(pausedAt ?? .now) > 300 {
                if liveActivity.isRunning { liveActivity.end() }
                return
            }
        case .playing:
            pausedAt = nil
        }
        stoppedStreak = 0

        let style = loadLAStyle()
        let styleKey = "\(style.prefs.theme.rawValue)|\(style.prefs.layout.rawValue)|\(style.prefs.artworkStyle.rawValue)|\(style.prefs.textAlignment.rawValue)|\(style.prefs.fontStyle.rawValue)|\(style.prefs.lyricScale.rawValue)|\(style.prefs.showTrackInfo)|\(style.prefs.showControls)|\(style.prefs.showNextLine)|\(style.prefs.showProgressBar)|\(style.prefs.animationsEnabled)|\(style.prefs.karaokeEnabled)"

        guard let signature else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }
        let artworkURL = provider?.lastAlbumImageURL
        let artworkReady = artworkURL == nil || SharedNowPlaying.cachedArtwork(for: artworkURL) != nil
        // NOTE: never end the activity just because lyrics are momentarily
        // unavailable — starting a new one is impossible from the background,
        // so ending it here would kill lock-screen lyrics until the app is
        // reopened (this exact bug shipped once; see placeholder path below).
        guard let document = lyrics.document else {
            // Update the placeholder AT MOST once per state change — calling
            // update() every tick (4/s) trips ActivityKit's rate limiter and
            // gets the activity's updates parked by the system.
            let placeholderKey = "\(signature.title)|\(lyrics.isAwaitingLyrics)|\(artworkReady)"
            if liveActivity.isRunning, placeholderKey != lastLAPlaceholderKey {
                lastLAPlaceholderKey = placeholderKey
                let placeholderState: LyricsActivityAttributes.ContentState = {
                    // Anchors + accent included so neither the progress bar
                    // nor the theme flickers for the ~1s lyrics are loading.
                    let anchors = status.map { PlaybackAnchors(status: $0, duration: signature.duration) }
                    return LyricsActivityAttributes.ContentState(
                        trackTitle: signature.title,
                        artistName: signature.artist,
                        albumImageURL: provider?.lastAlbumImageURL,
                        currentLine: lyrics.isAwaitingLyrics ? "Finding lyrics…" : "No lyrics for this track",
                        isPlaying: status?.state == .playing,
                        progressStart: anchors?.startDate,
                        progressEnd: anchors?.endDate,
                        frozenProgress: anchors?.frozenFraction,
                        albumDominantRGB: style.prefs.theme == .album
                            ? style.accent.map { [$0.r, $0.g, $0.b] } : nil
                    )
                }()
                liveActivity.update(state: placeholderState)
                lastSentLAHash = laContentHash(placeholderState)
                lastLAUpdateAt = .now
                lastLAArtworkReady = artworkReady
                lastAppliedStyleKey = styleKey
                lastSentAccent = placeholderState.albumDominantRGB
            }
            return
        }

        if !liveActivity.isRunning {
            // Recovery: try adoption AND fresh creation on every tick. iOS
            // rejects what isn't allowed (background creation); attempting is
            // free and self-heals faster than gating on scenePhase guesses.
            let startState = contentState(document: document, style: style.prefs, albumAccent: style.accent)
            liveActivity.start(state: startState)
            lastLineIndex = lyrics.currentIndex
            lastLAUpdateAt = .now
            lastLASentIsPlaying = startState.isPlaying
            lastLASentTrack = "\(startState.trackTitle)|\(startState.artistName)|\(startState.albumImageURL ?? "-")|\(document.lines.count)"
            lastLAArtworkReady = artworkReady
            lastSentLAHash = laContentHash(startState)
            lastAppliedStyleKey = styleKey
            lastSentAccent = startState.albumDominantRGB
            lastAppliedLAOffset = lyrics.userOffset
            return
        }

        // Update diet + honest staleness: send when content the user READS
        // changes (line, track, play state, style/accent), plus a slow
        // keep-alive pulse so the card's staleDate never expires mid-gap —
        // otherwise lyric gaps fake-stale the card and ↻ stops meaning
        // anything. The progress bar advances itself via TimelineView on the
        // widget's own clock.
        let targetState = contentState(document: document, style: style.prefs, albumAccent: style.accent)
        let trackKey = "\(targetState.trackTitle)|\(targetState.artistName)|\(targetState.albumImageURL ?? "-")|\(document.lines.count)"
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
        let urgent = trackChanged || playChanged || artworkChanged || accentChanged || styleChanged || offsetChanged
        let sinceLastSend = now.timeIntervalSince(lastLAUpdateAt ?? .distantPast)
        // The in-app scroller advances on a 250ms clock. ActivityKit still
        // applies its own device-level budget, but a four-second app-side gate
        // made normal lyric changes visibly stale. Coalescing in the controller
        // prevents overlapping sends, so this can be responsive without a
        // request storm.
        let minGapPassed = sinceLastSend >= 1.5
        let lineSend = lineChanged && minGapPassed && !throttleCapped(now: now)
        // Keep-alive pulse: refresh staleness at most ~2/min during playback
        // so isStale (and therefore ↻) only ever means a genuinely dead feed.
        let keepAliveSend = status?.state == .playing && !urgent && sinceLastSend >= 30
        // Reconciliation self-heal: ActivityKit silently drops background
        // updates now and then. If what we last sent differs from current
        // truth for >45s, resend. Generous window — frequent reconciles were
        // part of the update spam that invited throttling in the first place.
        let reconciling = sinceLastSend >= 60
            && lastSentLAHash != nil
            && lastSentLAHash != laContentHash(targetState)
        if reconciling && !(urgent || lineSend || keepAliveSend) {
            DiagnosticsLog.append("la reconcile: resending drifted state")
        }
        if urgent || lineSend || keepAliveSend || reconciling {
            liveActivity.update(state: targetState)
            lastLAUpdateAt = now
            lastLineIndex = lyrics.currentIndex
            lastLASentIsPlaying = targetState.isPlaying
            lastLASentTrack = trackKey
            lastLAArtworkReady = artworkReady
            lastSentLAHash = laContentHash(targetState)
            lastAppliedStyleKey = styleKey
            lastSentAccent = targetState.albumDominantRGB
            lastAppliedLAOffset = lyrics.userOffset
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
    @ObservationIgnored private var lastSentAccent: [Double]?

    /// Stable fingerprint of a ContentState. Anchor dates are second-rounded:
    /// during steady playback startDate/endDate are constant anyway, so any
    /// hash drift means real content (title, line, play state, bar) moved.
    private func laContentHash(_ s: LyricsActivityAttributes.ContentState) -> String {
        "\(s.trackTitle)|\(s.artistName)|\(s.albumImageURL ?? "-")|\(s.currentLine)|\(s.nextLine ?? "-")|\(s.isPlaying)"
            + "|\(s.progressStart.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.progressEnd.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.frozenProgress.map { Int(($0 * 100).rounded()) } ?? -1)"
            + "|\(s.karaokeStartDate.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.karaokeEndDate.map { $0.timeIntervalSince1970.rounded() } ?? -1)"
            + "|\(s.frozenKaraokeProgress.map { Int(($0 * 100).rounded()) } ?? -1)"
            + "|\(s.albumDominantRGB.map { $0.map { Int($0 * 255) } } ?? [])"
    }

    /// Loads current appearance prefs and keeps the album dominant color fresh
    /// when Album mode is active. Called once per tick before LA work.
    private func loadLAStyle() -> (prefs: LAStylePrefs, accent: RGB?) {
        let prefs = LAStyleStore.load()
        guard prefs.theme == .album else { return (prefs, nil) }
        if let art = provider?.lastAlbumImageURL, art != albumAccentForURL {
            albumAccentForURL = art
            Task { [weak self] in
                let color = await DominantColorExtractor.extract(from: art)
                guard let self, color != self.albumAccent else { return }
                self.albumAccent = color
                DiagnosticsLog.append("album accent extracted")
            }
        }
        return (prefs, albumAccent)
    }
    private var scenePhase: ScenePhase = .inactive
    @ObservationIgnored private var lastLASentIsPlaying = false
    @ObservationIgnored private var lastLASentTrack: String?
    /// Consecutive stopped/no-device observations (blip immunity for LA teardown).
    @ObservationIgnored private var stoppedStreak = 0

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
        // Twelve future lines keep the Live Activity payload compact while
        // covering normal lyric gaps. ActivityKit updates refresh the window
        // before it runs out, and the widget advances locally at each date.
        let scheduled = scheduledLines(for: document, limit: 12)
        return .init(
            trackTitle: signature?.title ?? document.track.title,
            artistName: signature?.artist ?? document.track.artist,
            albumImageURL: provider?.lastAlbumImageURL,
            currentLine: current,
            nextLine: next,
            isPlaying: status?.state == .playing,
            progressStart: anchors?.startDate,
            progressEnd: anchors?.endDate,
            frozenProgress: anchors?.frozenFraction,
            scheduledLines: scheduled.isEmpty ? nil : scheduled,
            karaokeStartDate: karaoke.start,
            karaokeEndDate: karaoke.end,
            frozenKaraokeProgress: karaoke.frozen,
            albumDominantRGB: dominant
        )
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
            : lineStart + 4
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
                                limit: Int) -> [WidgetLyricSnapshot.ScheduledLine] {
        guard status?.state == .playing else { return [] }
        let base = lyrics.displayPosition
        let now = Date.now
        return Array(document.lines.compactMap { line in
            // SyncEngine applies the user's offset to playback position when
            // selecting the active line. Apply the equivalent inverse shift
            // to the wall-clock schedule so the app and Live Activity remain
            // aligned after an offset adjustment too.
            let delta = line.time + lyrics.userOffset - base
            guard delta > 0.05 else { return nil }
            return .init(date: now.addingTimeInterval(delta), text: line.text)
        }.prefix(limit))
    }
}
