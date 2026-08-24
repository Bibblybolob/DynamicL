import SwiftUI
import WidgetKit
import LyricCore

/// Facade wiring Spotify auth + polling + lyrics into a single observable model.
@MainActor
@Observable
final class AppModel {
    let auth = SpotifyAuthManager()
    private(set) var provider: SpotifyProvider?
    let lyrics = LyricsService()
    let liveActivity = LiveActivityController()
    private let watchSync = WatchSyncManager.shared

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
        if auth.isConnected {
            startPolling()
        }
        if ProcessInfo.processInfo.arguments.contains("-demoActivity") {
            startDemo()
        }
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
        liveActivity.end()
        keeper.stop()
    }

    func handleScenePhase(_ phase: ScenePhase) {
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
            "Dynamicallyrics",
        ]
        let track = TrackSignature(title: "Demo Song", artist: "Dynamicallyrics")
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

        lyrics.tick()
        manageKeepAlive()
        syncLiveActivity()
        syncWidgetSnapshot()
        syncWatchSnapshot()
        consumeWidgetCommand()
    }

    /// Picks up play/pause requests made from widgets / Live Activity buttons.
    private func consumeWidgetCommand() {
        guard PlaybackCommandBus.consume() == .togglePlayPause else { return }
        Task { [weak self] in
            guard let self else { return }
            let accepted = await provider?.togglePlayPause() ?? false
            if !accepted {
                // The real state never changed; drop the optimistic flip.
                SharedNowPlaying.setPlayingOverride(nil)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func syncWidgetSnapshot() {
        // Track changed but the new song's lyrics haven't loaded yet: publish an
        // interim snapshot for the NEW track so widgets don't keep rendering the
        // previous song's timeline until WidgetKit's reload budget allows an
        // update. The full snapshot with scheduled lines follows once lyrics land.
        if let signature, status?.state == .playing,
           lyrics.document == nil || lyrics.document?.track != signature {
            let key = "interim|\(signature.title)|\(signature.artist)"
            guard key != lastPublishedWidgetKey else { return }
            lastPublishedWidgetKey = key
            widgetIdlePublished = false
            SharedNowPlaying.save(
                WidgetLyricSnapshot(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: provider?.lastAlbumImageURL,
                    currentLine: lyrics.isLoading ? "Loading lyrics…" : "♪",
                    isPlaying: true
                )
            )
            reloadWidgetTimelines()
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
        let key = "\(signature.title)|\(signature.artist)|\(index)|\(isPlaying)|\(document.lines.count)"
        guard key != lastPublishedWidgetKey else { return }
        lastPublishedWidgetKey = key
        widgetIdlePublished = false

        var scheduled: [WidgetLyricSnapshot.ScheduledLine] = []
        if isPlaying {
            let base = lyrics.displayPosition
            let now = Date.now
            scheduled = document.lines.compactMap { line in
                let delta = line.time - base
                guard delta > 0.05 else { return nil }
                return .init(date: now.addingTimeInterval(delta), text: line.text)
            }
            if scheduled.count > 40 {
                scheduled = Array(scheduled.prefix(40))
            }
        }

        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        SharedNowPlaying.save(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: provider?.lastAlbumImageURL,
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
        let reloadKey = "\(signature.title)|\(signature.artist)|\(isPlaying)|\(scheduled.isEmpty ? "nosched" : "sched")"
        if reloadKey != lastReloadedWidgetKey {
            lastReloadedWidgetKey = reloadKey
            reloadWidgetTimelines()
        }
    }

    @ObservationIgnored private var lastReloadedWidgetKey: String?

    private func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: "CurrentLineWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "LockscreenLyricWidget")
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

    private func manageKeepAlive() {
        let shouldRun = (auth.isConnected || demoActive)
            && status?.state == .playing
            && lockScreenLyricsEnabled
        if shouldRun {
            keeper.start()
        } else {
            keeper.stop()
        }
    }

    private func syncLiveActivity() {
        guard lockScreenLyricsEnabled, auth.isConnected || demoActive else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }

        switch status?.state {
        case .stopped, .none:
            if liveActivity.isRunning { liveActivity.end() }
            pausedAt = nil
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

        guard let signature else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }
        guard let document = lyrics.document else {
            if !lyrics.isLoading, liveActivity.isRunning { liveActivity.end() }
            return
        }

        // One activity for the whole session: song changes are plain updates
        // (track info is part of ContentState), which work from the background.
        // NOTE: never end the activity just because lyrics are momentarily
        // unavailable — starting a new one is impossible from the background,
        // so ending it here would kill lock-screen lyrics until the app is
        // reopened. Only stopped/paused-timeout paths end it.
        guard let document = lyrics.document else {
            // Update the placeholder AT MOST once per state change — calling
            // update() every tick (4/s) trips ActivityKit's rate limiter and
            // gets the activity's updates parked by the system.
            let placeholderKey = "\(signature.title)|\(lyrics.isAwaitingLyrics)"
            if liveActivity.isRunning, placeholderKey != lastLAPlaceholderKey {
                lastLAPlaceholderKey = placeholderKey
                liveActivity.update(state: .init(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    currentLine: lyrics.isAwaitingLyrics ? "Finding lyrics…" : "No lyrics for this track",
                    isPlaying: status?.state == .playing
                ))
            }
            return
        }

        if !liveActivity.isRunning {
            liveActivity.start(state: contentState(document: document))
            lastLineIndex = lyrics.currentIndex
            return
        }

        // Update sparingly: ActivityKit escalates delays on high-frequency
        // background updates. Line updates capped at ~6s. Track changes and
        // play/pause bypass the throttle — a stale title is worse than a
        // slightly higher chance of deferral.
        let targetState = contentState(document: document)
        let trackKey = "\(targetState.trackTitle)|\(document.lines.count)"
        let trackChanged = trackKey != lastLASentTrack
        let lineChanged = lyrics.currentIndex != lastLineIndex
        let playChanged = targetState.isPlaying != lastLASentIsPlaying
        if lineChanged || playChanged || trackChanged {
            let now = Date.now
            let urgent = playChanged || trackChanged
            if urgent || now.timeIntervalSince(lastLASentAt ?? .distantPast) >= 10 {
                liveActivity.update(state: targetState)
                lastLASentAt = now
                lastLineIndex = lyrics.currentIndex
                lastLASentIsPlaying = targetState.isPlaying
                lastLASentTrack = trackKey
            }
        }
    }

    @ObservationIgnored private var lastLAPlaceholderKey: String?
    @ObservationIgnored private var lastLASentAt: Date?
    @ObservationIgnored private var lastLASentIsPlaying = false
    @ObservationIgnored private var lastLASentTrack: String?

    private func contentState(document: LyricsDocument) -> LyricsActivityAttributes.ContentState {
        let index = lyrics.currentIndex
        let current = index.map { document.lines[$0].text } ?? "♪"
        let next = index.map { $0 + 1 < document.lines.count ? document.lines[$0 + 1].text : nil } ?? nil
        return .init(
            trackTitle: signature?.title ?? document.track.title,
            artistName: signature?.artist ?? document.track.artist,
            currentLine: current,
            nextLine: next,
            isPlaying: status?.state == .playing
        )
    }
}
