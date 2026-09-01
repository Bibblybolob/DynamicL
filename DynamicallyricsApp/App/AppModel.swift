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
    private var widgetPausedAt: Date?
    private var lastPublishedWidgetKey: String?
    @ObservationIgnored private var widgetCommandTask: Task<Void, Never>?
    @ObservationIgnored private var localSessionAuthAttemptedAt: Date?
    @ObservationIgnored private var localSessionAuthAttemptedRequestAt: TimeInterval?
    @ObservationIgnored private var lastWidgetPublishedPosition: TimeInterval?
    @ObservationIgnored private var lastWidgetPublishedAt: Date?
    @ObservationIgnored private var lastWidgetPublishedRate: Double = 1
    private var widgetIdlePublished = false

    private(set) var demoActive = false
    private static let localSessionEnabledKey = "experimentalLocalLyricsSessionEnabled"
    private(set) var localSessionActive = false

    /// Enables the phone-owned lyric session while the system permits normal
    /// background execution. OpenLyrics does not request a location or audio
    /// workaround to keep this process alive.
    var localSessionEnabled: Bool {
        get {
            // Automatic lyrics is the normal private-beta path. Preserve an
            // explicit opt-out from an older build, but do not make a new
            // installation press Show Lyrics before every listening session.
            UserDefaults.standard.object(forKey: Self.localSessionEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.localSessionEnabledKey)
            // Keep this setting for migration compatibility. It is a single
            // automatic-lyrics consent switch. It does not request extra
            // background execution from iOS and it never creates a per-song
            // Show Lyrics gate.
            if newValue {
                // Turning Automatic Lyrics on is an explicit recovery action.
                // Clear an old ActivityKit or server dismissal left by a
                // previous build before deciding whether this session can run.
                liveActivity.allowRecoveryStart(reason: "Automatic Lyrics switch")
                SyncServerClient.shared.resetDismissalForNewSession()
            }
            localSessionActive = newValue && lockScreenLyricsEnabled && !liveActivity.wasDismissed
            SyncServerClient.shared.requestImmediateHeartbeat()
            if newValue {
                DiagnosticsLog.append("automatic lyrics enabled")
                provider?.kick()
            } else if liveActivity.isRunning {
                liveActivity.end()
            }
            SharedNowPlaying.setLiveActivityControlEnabled(localSessionActive)
            updatePollingProfile()
        }
    }

    var lockScreenLyricsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockScreenLyricsEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "lockScreenLyricsEnabled")
            if !newValue {
                liveActivity.end()
                localSessionActive = false
                SharedNowPlaying.setLiveActivityControlEnabled(false)
            } else {
                // Enabling the preference is the one-time consent. Restore
                // the local owner immediately and clear a stale ActivityKit
                // dismissal left by a previous app build.
                liveActivity.allowRecoveryStart(reason: "Lock Screen Lyrics switch")
                SyncServerClient.shared.resetDismissalForNewSession()
                localSessionActive = localSessionEnabled && !liveActivity.wasDismissed
                SharedNowPlaying.setLiveActivityControlEnabled(localSessionActive)
                provider?.kick()
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
                    requiresUserStart: false,
                    force: true
                )
            }
        }
    }

    init() {
        // Automatic lyrics is a one-time preference. Recover the local owner
        // after relaunch without requiring a per-session Lock Screen action.
        // A manual dismissal remains suppressed until a new playback session.
        localSessionActive = localSessionEnabled
            && lockScreenLyricsEnabled
            && !liveActivity.wasDismissed
        if localSessionActive {
            // Keep old server registrations compatible with the automatic
            // path. New content states always set this field to false.
            SyncServerClient.shared.markFirstUseCompleted()
        }
        liveActivity.onActivityEnded = { [weak self] in
            guard let self else { return }
            // A normal system end is recoverable. A user dismissal remains
            // suppressed by LiveActivityController until a new playback
            // session is confirmed.
            self.localSessionActive = self.localSessionEnabled
                && self.lockScreenLyricsEnabled
                && !self.liveActivity.wasDismissed
            SharedNowPlaying.setLiveActivityControlEnabled(self.localSessionActive)
            self.updatePollingProfile()
        }
        SharedNowPlaying.setLiveActivityControlEnabled(
            localSessionActive && lockScreenLyricsEnabled
        )
        startTicker()
        watchSync.activateIfNeeded()
        installNowPlayingBridge()
        if auth.isConnected {
            startPolling()
            if lockScreenLyricsEnabled && localSessionEnabled {
                activateLocalLyricsSession(source: "automatic startup")
            }
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
                    SharedNowPlaying.setPlayingOverride(
                        current.state != .playing,
                        trackID: self.provider?.lastTrackID
                    )
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
                    SharedNowPlaying.setPlayingOverride(true, trackID: self.provider?.lastTrackID)
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
                    SharedNowPlaying.setPlayingOverride(false, trackID: self.provider?.lastTrackID)
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
            connectError = "Enter your Spotify Client ID in the app first."
            return
        }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            try await auth.connect()
            startPolling()
            if lockScreenLyricsEnabled && localSessionEnabled {
                activateLocalLyricsSession(source: "automatic startup")
            }
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
        SharedNowPlaying.setLiveActivityControlEnabled(false)
        SharedNowPlaying.clearAll()
        SyncServerClient.shared.resetFirstUseGate()
        watchSync.clear()
        reloadWidgetTimelines()
    }

    /// Starts the phone-owned Live Activity session from a direct user action.
    /// The same method is used by the in-app button and the Control Center
    /// request after it is consumed. Keeping this path together is
    /// important: it enables the local poller, sends an immediate Spotify
    /// probe, and lets the current ticker create or update the Activity.
    func startLocalLyricsSession() {
        guard auth.isConnected || demoActive else {
            DiagnosticsLog.append("local session ignored: Spotify is not connected")
            return
        }
        // This is a direct recovery action. It must override a dismissal that
        // belongs to an old TestFlight build or an expired server session.
        liveActivity.allowRecoveryStart(reason: "Start Lock Screen Lyrics")
        SyncServerClient.shared.resetDismissalForNewSession()
        if !lockScreenLyricsEnabled {
            lockScreenLyricsEnabled = true
        }
        activateLocalLyricsSession(source: "user", forceRestart: true)
        provider?.kick()
        provider?.burst(count: 10)
        tick()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        updatePollingProfile()
        switch phase {
        case .active:
            if auth.isConnected { startPolling() }
        case .background:
            // The server and ActivityKit schedule provide background recovery.
            // Do not request a high-power location or audio keep-alive.
            provider?.kick()
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
        SharedNowPlaying.setLiveActivityControlEnabled(false)
    }

    private func startPolling() {
        if provider == nil {
            provider = SpotifyProvider(auth: auth)
        }
        updatePollingProfile()
        provider?.start()
    }

    private func updatePollingProfile() {
        // iOS background execution is not extended with location or silent
        // audio. While the user has an active local session and the app is
        // locked, use a bounded one-second probe profile. This catches
        // external Spotify/headphone skips, which do not pass through our
        // command handlers, without keeping the high-power profile while the
        // app is in the foreground.
        let aggressive = localSessionActive
            && localSessionEnabled
            && lockScreenLyricsEnabled
            && scenePhase != .active
        provider?.setAggressiveBackgroundMode(aggressive)
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
    private static let localSessionWarmupLimit: TimeInterval = 15
    @ObservationIgnored private var localSessionWarmupUntil = Date.distantPast

    private func tick() {
        // Heartbeat (throttled to ~5s): proves whether the process is alive &
        // polling while backgrounded/locked. Gaps in timestamps = suspended.
        tickCount += 1
        if tickCount % 20 == 0 {
            DiagnosticsLog.append("hb \(String(format: "%.1f", lyrics.displayPosition))s doc=\(lyrics.document != nil) la=\(liveActivity.isRunning)")
        }
        // Process the persistent Control Center state before one-shot start
        // requests. This prevents a queued start from resurrecting a session
        // after the user has just switched lyrics off.
        consumeLiveActivityControlRequest()
        consumeLocalSessionRequest()
        consumeLiveActivityEnableRequest()
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
            // A playing Spotify item is the automatic activation event. The
            // recovery button remains available, but ordinary playback does
            // not require a per-session Show Lyrics tap.
            if lockScreenLyricsEnabled,
               localSessionEnabled,
               status?.state == .playing,
               !localSessionActive {
                activateLocalLyricsSession(source: "Spotify playback")
            }
        } else if demoActive {
            lyrics.update(signature: signature, status: status)
        }

        prefetchAlbumArtworkIfNeeded()
        lyrics.tick()
        markRecoveredIfSilenceBroken()
        revivePollerIfNeeded()
        publishNowPlayingIfDue()
        syncLiveActivity()
        syncServerHeartbeat()
        syncWidgetSnapshot()
        syncWatchSnapshot()
        consumeWidgetCommand()
    }

    /// Consumes a request written by the iOS 18 Control Center control or the
    /// Live Activity Show Lyrics action. This is the same one-shot activation
    /// as the in-app button. The explicit action starts the phone-owned lyric
    /// session; the separate high-power beta setting controls background
    /// polling after lock.
    private func consumeLocalSessionRequest() {
        let now = Date.now
        guard let requestDate = SharedNowPlaying.localSessionStartRequestDate(now: now) else {
            localSessionAuthAttemptedAt = nil
            localSessionAuthAttemptedRequestAt = nil
            return
        }
        // A request expires after two minutes. This covers the Spotify app
        // authorization round trip. Permit a later user action to start a
        // fresh authentication attempt, but never launch a new sign-in task
        // on every 250 ms model tick after one failed attempt.
        if let attemptedAt = localSessionAuthAttemptedAt,
           localSessionAuthAttemptedRequestAt == requestDate.timeIntervalSince1970,
           now.timeIntervalSince(attemptedAt) >= 125 {
            localSessionAuthAttemptedAt = nil
            localSessionAuthAttemptedRequestAt = nil
        }

        // Do not consume the request before Spotify authentication is ready.
        // The first-use Live Activity action opens the app, and authentication
        // may finish a few seconds later. Keeping the request in the shared
        // mailbox lets the next tick complete the same handoff without asking
        // the user to press Show Lyrics a second time.
        guard auth.isConnected || demoActive else {
            // A cold launch can reach the model ticker before SwiftUI has
            // installed a key window. Wait for the active scene before asking
            // AuthenticationServices to present Spotify sign-in.
            guard scenePhase == .active else { return }
            // Repeated taps can arrive while the first Spotify authorization
            // sheet is still being presented. Do not start a second
            // authentication task or let two callbacks race the same
            // first-use request.
            guard !isConnecting else { return }
            guard localSessionAuthAttemptedAt == nil
                    || localSessionAuthAttemptedRequestAt != requestDate.timeIntervalSince1970 else {
                return
            }
            localSessionAuthAttemptedAt = now
            localSessionAuthAttemptedRequestAt = requestDate.timeIntervalSince1970
            DiagnosticsLog.append("local session request opening Spotify sign-in")
            Task { [weak self] in
                guard let self else { return }
                await self.connect()
                // Do not clear the attempt marker after a cancelled or failed
                // authorization. The request is still one-shot: reopening the
                // sign-in sheet on every 250 ms model tick is disruptive and
                // can make the Live Activity appear frozen. A later tap writes
                // a new request date and is allowed to try again; otherwise
                // the existing request expires with its normal two-minute TTL.
            }
            return
        }
        localSessionAuthAttemptedAt = nil
        localSessionAuthAttemptedRequestAt = nil
        // A Live Activity action is bound to the card that the user pressed.
        // Control Center and Shortcuts leave this optional, so they continue
        // to use the same path without an Activity identity.
        guard SharedNowPlaying.consumeLocalSessionStartRequest(
            activityID: liveActivity.activityID
        ) else { return }
        liveActivity.allowRecoveryStart(reason: "Control or Shortcut")
        SyncServerClient.shared.resetDismissalForNewSession()
        if !lockScreenLyricsEnabled {
            lockScreenLyricsEnabled = true
        }
        activateLocalLyricsSession(source: "control or shortcut")
        provider?.kick()
        provider?.burst(count: 10)
    }

    /// Consumes the iOS 18 Control Center on/off request. The actual start is
    /// still performed by `consumeLocalSessionRequest`, which preserves the
    /// Spotify authorization round trip. Turning the control off is handled
    /// here because it must cancel any pending start before the next ticker.
    private func consumeLiveActivityControlRequest() {
        guard let enabled = SharedNowPlaying.consumeLiveActivityControlRequest() else {
            return
        }

        if enabled {
            // The intent also writes a one-shot local-session request. If a
            // caller only sent the state request, start immediately when the
            // app already has Spotify access.
            if auth.isConnected || demoActive,
               !localSessionActive,
               !SharedNowPlaying.hasLocalSessionStartRequest() {
                // A state-only request can arrive after the user turned the
                // control off. Restore the preference before starting so the
                // next sync tick does not immediately end the new Activity.
                if !lockScreenLyricsEnabled {
                    lockScreenLyricsEnabled = true
                }
                activateLocalLyricsSession(source: "control center")
                provider?.kick()
                provider?.burst(count: 10)
            }
            DiagnosticsLog.append("Live Activity control enabled")
            return
        }

        // Consume a queued start request before ending the session. This
        // makes an off tap authoritative even if it follows an old on tap.
        SharedNowPlaying.discardLocalSessionStartRequest()
        localSessionActive = false
        SharedNowPlaying.setLiveActivityControlEnabled(false)
        if lockScreenLyricsEnabled {
            lockScreenLyricsEnabled = false
        } else {
            liveActivity.end()
            updatePollingProfile()
        }
        DiagnosticsLog.append("Live Activity control disabled")
    }

    /// Handles the Shortcuts automation path. It enables the same one-time
    /// automatic session as ordinary Spotify playback. The request is idempotent.
    private func consumeLiveActivityEnableRequest() {
        guard SharedNowPlaying.consumeLiveActivityEnableRequest() else { return }
        liveActivity.allowRecoveryStart(reason: "Shortcut")
        SyncServerClient.shared.resetDismissalForNewSession()
        if !lockScreenLyricsEnabled {
            lockScreenLyricsEnabled = true
        }
        if auth.isConnected || demoActive {
            activateLocalLyricsSession(source: "Shortcut")
            provider?.kick()
            provider?.burst(count: 10)
            SyncServerClient.shared.wake(reason: "shortcut")
        }
        DiagnosticsLog.append("Live Activity enabled by Shortcut")
    }

    private func activateLocalLyricsSession(
        source: String,
        forceRestart: Bool = false
    ) {
        // Drop any older coalesced state before the phone becomes the local
        // owner, so a late placeholder cannot hide newly loaded lyrics.
        liveActivity.interruptPendingUpdates(reason: "automatic lyric session started")
        // This path does not request Location permission or change the device
        // power profile. The short warm-up only covers the first Spotify poll.
        localSessionWarmupUntil = .now.addingTimeInterval(Self.localSessionWarmupLimit)
        // Announce the ownership change on the next model tick. This prevents
        // a server fallback update from racing the first phone lyric state.
        SyncServerClient.shared.requestImmediateHeartbeat()
        SyncServerClient.shared.markFirstUseCompleted()
        localSessionActive = true
        if let activityID = liveActivity.activityID {
            SharedNowPlaying.markLiveActivityFirstUseCompleted(for: activityID)
        }
        SharedNowPlaying.setLiveActivityControlEnabled(true)
        // Do not wait for Spotify's player endpoint or the lyric provider
        // before asking ActivityKit for a card. The bootstrap state is small
        // and visible immediately; the normal sync path replaces it with the
        // current track as soon as playback arrives.
        startBootstrapLiveActivity(forceRestart: forceRestart)
        // Refresh after the session becomes active, including when this action
        // is invoked from the Lock Screen or Control Center.
        updatePollingProfile()
        DiagnosticsLog.append("local session started by \(source)")
    }

    /// Creates a minimal ActivityKit surface before Spotify has returned its
    /// first player sample. Previously the start request lived only inside
    /// `syncLiveActivity`, after valid playback metadata was available. A slow
    /// or failed Spotify request therefore looked exactly like Live Activity
    /// was broken and left no Lock Screen recovery action.
    private func startBootstrapLiveActivity(forceRestart: Bool = false) {
        guard lockScreenLyricsEnabled,
              (!liveActivity.isRunning || forceRestart),
              !liveActivity.wasDismissed else { return }

        let playing = status?.state == .playing
        let state = stamped(
            LyricsActivityAttributes.ContentState(
                trackTitle: signature?.title ?? "OpenLyrics",
                artistName: signature?.artist ?? "Spotify",
                albumImageURL: provider?.lastAlbumImageURL,
                currentLine: signature == nil
                    ? "Connecting to Spotify…"
                    : "Finding lyrics…",
                isPlaying: playing,
                schemaVersion: 2,
                source: .phone,
                trackID: provider?.lastTrackID,
                requiresUserStart: false
            )
        )
        DiagnosticsLog.append("LA bootstrap requested")
        if forceRestart {
            liveActivity.restartForRecovery(state: state)
        } else {
            liveActivity.start(state: state)
        }
    }

    private func syncServerHeartbeat() {
        guard auth.isConnected, let provider else { return }
        // Lease ownership follows the local poll loop, not the last successful
        // Spotify response. A temporary Spotify or network failure must not
        // make the server race the phone while the phone can still render its
        // already-loaded lyric schedule. Immediately after Show Lyrics is
        // pressed, the poller can be running before its first sample stamps
        // lastLoopActivityAt; count that short startup interval as healthy so
        // an older server state cannot win the handoff.
        let withinSessionWarmup = Date.now < localSessionWarmupUntil
        let healthy = provider.isLoopLikelyAlive
            || (withinSessionWarmup && localSessionActive && provider.isPolling)
        SyncServerClient.shared.heartbeat(
            activityState: liveActivity.syncActivityState,
            trackID: provider.lastTrackID,
            lyricOffset: lyrics.userOffset,
            localRevision: localLARevision,
            healthy: healthy,
            autoStartEnabled: lockScreenLyricsEnabled,
            albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
            requiresUserStart: false
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
        // Transport calls are asynchronous. Serialize them so rapid taps do
        // not run Spotify commands concurrently and apply responses out of
        // order. The queue retains later commands until the current one ends.
        guard widgetCommandTask == nil else { return }
        guard let envelope = PlaybackCommandBus.consumeEnvelope() else { return }
        DiagnosticsLog.append("cmd bus: \(envelope.command.rawValue) id=\(envelope.id.uuidString.prefix(8))")
        widgetCommandTask = Task { [weak self] in
            defer { self?.widgetCommandTask = nil }
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
                        SharedNowPlaying.setPlayingOverride(
                            current.state != .playing,
                            trackID: localProvider.lastTrackID
                        )
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
           status?.state == .playing || status?.state == .paused,
           lyrics.document?.track != signature {
            let artworkURL = provider?.lastAlbumImageURL
            let snapshotNow = Date.now
            let artworkReady = artworkURL == nil
                || artworkURL.flatMap(ArtworkFileCache.data(for:)) != nil
            let durationKey = signature.duration.map { String(format: "%.3f", $0) } ?? "-"
            let accentKey = albumAccent.map { "\($0.r),\($0.g),\($0.b)" } ?? "-"
            let key = "interim|\(provider?.lastTrackID ?? "-")|\(signature.title)|\(signature.artist)|\(durationKey)|\(artworkURL ?? "")|\(artworkReady)|\(accentKey)|playing=\(status?.state == .playing)|loading=\(lyrics.isLoading)"
            guard key != lastPublishedWidgetKey else { return }
            lastPublishedWidgetKey = key
            widgetIdlePublished = false
            SharedNowPlaying.save(
                WidgetLyricSnapshot(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: artworkURL,
                    artworkKey: artworkURL.flatMap(ArtworkFileCache.key),
                    albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                    trackID: provider?.lastTrackID,
                    lyricOffsetMs: Int((lyrics.userOffset * 1_000).rounded()),
                    trackDuration: signature.duration,
                    playbackEndEpoch: status?.state == .playing
                        ? playbackEndEpoch(for: signature, at: snapshotNow) : nil,
                    playbackAnchorEpoch: status?.state == .playing
                        ? playbackAnchorEpoch(at: snapshotNow) : nil,
                    currentLine: lyrics.isLoading ? "Loading lyrics…" : "♪",
                    isPlaying: status?.state == .playing
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
        let artworkReady = artworkURL == nil
            || artworkURL.flatMap(ArtworkFileCache.data(for:)) != nil
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
        let durationKey = signature.duration.map { String(format: "%.3f", $0) } ?? "-"
        let accentKey = albumAccent.map { "\($0.r),\($0.g),\($0.b)" } ?? "-"
        let key = "\(provider?.lastTrackID ?? "-")|\(signature.title)|\(signature.artist)|\(index)|\(isPlaying)|\(document.lines.count)|\(durationKey)|\(offsetKey)|\(artworkURL ?? "")|\(artworkReady)|\(accentKey)|\(correctionKey)"
        guard key != lastPublishedWidgetKey else { return }
        lastPublishedWidgetKey = key
        widgetIdlePublished = false

        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        SharedNowPlaying.save(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: artworkURL,
                artworkKey: artworkURL.flatMap(ArtworkFileCache.key),
                albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                trackID: provider?.lastTrackID,
                lyricOffsetMs: Int((lyrics.userOffset * 1_000).rounded()),
                trackDuration: signature.duration,
                playbackEndEpoch: isPlaying ? playbackEndEpoch(for: signature, at: now) : nil,
                playbackAnchorEpoch: isPlaying ? playbackAnchorEpoch(at: now) : nil,
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
        let reloadKey = "\(provider?.lastTrackID ?? "-")|\(signature.title)|\(signature.artist)|\(durationKey)|\(isPlaying)|\(scheduled.isEmpty ? "nosched" : "sched")|\(artworkURL ?? "")|\(artworkReady)|\(accentKey)"
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
        guard ArtworkFileCache.data(for: urlString) == nil else { return }

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
        guard let signature,
              status?.state == .playing || status?.state == .paused else {
            return
        }
        if status?.state == .paused,
           let pauseDate = widgetPausedAt,
           Date.now.timeIntervalSince(pauseDate) > Self.liveActivityPauseGrace {
            return
        }

        // Publish the new track before its lyrics arrive. Without this
        // interim packet, the Watch keeps the previous song and its schedule
        // until the lyric request completes. This is the same handoff used by
        // the widget and Live Activity paths.
        if lyrics.document?.track != signature {
            let artworkURL = provider?.lastAlbumImageURL
            let snapshotNow = Date.now
            watchSync.publish(
                WidgetLyricSnapshot(
                    trackTitle: signature.title,
                    artistName: signature.artist,
                    albumImageURL: artworkURL,
                    artworkKey: artworkURL.flatMap(ArtworkFileCache.key),
                    albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                    trackID: provider?.lastTrackID,
                    lyricOffsetMs: Int((lyrics.userOffset * 1_000).rounded()),
                    trackDuration: signature.duration,
                    playbackEndEpoch: status?.state == .playing
                        ? playbackEndEpoch(for: signature, at: snapshotNow) : nil,
                    playbackAnchorEpoch: status?.state == .playing
                        ? playbackAnchorEpoch(at: snapshotNow) : nil,
                    currentLine: lyrics.isLoading ? "Loading lyrics…" : "♪",
                    isPlaying: status?.state == .playing
                )
            )
            return
        }

        guard let document = lyrics.document else { return }
        let index = lyrics.currentIndex ?? -1
        let current = index >= 0 && index < document.lines.count ? document.lines[index].text : "♪"
        let artworkURL = provider?.lastAlbumImageURL
        watchSync.publish(
            WidgetLyricSnapshot(
                trackTitle: signature.title,
                artistName: signature.artist,
                albumImageURL: artworkURL,
                artworkKey: artworkURL.flatMap(ArtworkFileCache.key),
                albumDominantRGB: albumAccent.map { [$0.r, $0.g, $0.b] },
                trackID: provider?.lastTrackID,
                lyricOffsetMs: Int((lyrics.userOffset * 1_000).rounded()),
                trackDuration: signature.duration,
                playbackEndEpoch: status?.state == .playing
                    ? playbackEndEpoch(for: signature, at: .now) : nil,
                playbackAnchorEpoch: status?.state == .playing
                    ? playbackAnchorEpoch(at: .now) : nil,
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
        // A remotely started Activity can wake the app before Spotify auth has
        // finished restoring its session. Preserve that adopted Activity while
        // auth loads; ending it here would defeat server recovery and force a
        // new first-use handoff on every cold launch. An explicit feature
        // disable still ends it immediately.
        guard lockScreenLyricsEnabled else {
            if liveActivity.isRunning { liveActivity.end() }
            return
        }
        guard auth.isConnected || demoActive else { return }

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
        // The platform can report a dismissed activity for a short time after
        // the user swipes it away. Do not spend every model tick attempting a
        // new start against that same playback session.
        if liveActivity.wasDismissed {
            return
        }

        let style = loadLAStyle()
        let styleKey = "\(style.prefs.theme.rawValue)|\(style.prefs.layout.rawValue)|\(style.prefs.artworkStyle.rawValue)|\(style.prefs.surfaceStyle.rawValue)|\(style.prefs.textAlignment.rawValue)|\(style.prefs.fontStyle.rawValue)|\(style.prefs.lyricScale.rawValue)|\(style.prefs.showTrackInfo)|\(style.prefs.showControls)|\(style.prefs.showNextLine)|\(style.prefs.showProgressBar)|\(style.prefs.animationsEnabled)|\(style.prefs.karaokeEnabled)"

        // Preserve the bootstrap card while Spotify has playback state but
        // has not supplied complete track metadata. Ending it here made the
        // Activity flash briefly and disappear during a slow player response.
        // A confirmed stop and the feature toggle remain the only paths that
        // remove this metadata-independent placeholder.
        guard let signature else { return }
        let artworkURL = provider?.lastAlbumImageURL
        let artworkReady = artworkURL == nil
            || artworkURL.flatMap(ArtworkFileCache.data(for:)) != nil
        // Publish the new track before the lyrics request completes. Waiting
        // for LRCLIB here leaves the old card or music-note placeholder visible
        // during the whole network lookup. The placeholder is a normal
        // automatic state, not a per-session Show Lyrics gate.
        guard let document = lyrics.document else {
            // Update the placeholder at most once per state change. ActivityKit
            // rate-limits repeated updates, and the app tick runs four times a
            // second.
            let placeholderKey = "\(provider?.lastTrackID ?? "-")|\(signature.title)|\(signature.artist)|\(provider?.lastAlbumImageURL ?? "-")|\(status?.state == .playing)|\(lyrics.isAwaitingLyrics)|\(artworkReady)|\(styleKey)|\(String(format: "%.3f", lyrics.userOffset))|start=\(localSessionActive)"
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
                    progressEndEpoch: anchors?.endDate?.timeIntervalSince1970,
                    requiresUserStart: false
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
                lastAppliedPlaybackChangeAt = provider?.lastPlaybackChangeAt
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
            lastLASentTrack = "\(startState.trackID ?? "-")|\(startState.trackTitle)|\(startState.artistName)|\(startState.albumImageURL ?? "-")|\(document.lines.count)|duration=\(signature.duration.map { String(format: "%.3f", $0) } ?? "-")"
            lastLAArtworkReady = artworkReady
            lastSentLAHash = laContentHash(startState)
            lastAppliedStyleKey = styleKey
            lastSentAccent = startState.albumDominantRGB
            lastAppliedLAOffset = lyrics.userOffset
            lastSentLASchedule = startState.resolvedScheduledLines
            lastAppliedLAProgressStartEpoch = startState.progressStartEpoch
            lastAppliedPlaybackChangeAt = provider?.lastPlaybackChangeAt
            return
        }

        // Update diet + honest staleness: send when content the user READS
        // changes (line, track, play state, style/accent), plus a slow
        // keep-alive pulse so the card's staleDate never expires mid-gap —
        // otherwise lyric gaps fake-stale the card and ↻ stops meaning
        // anything. The progress bar advances itself via TimelineView on the
        // widget's own clock.
        let targetState = contentState(document: document, style: style.prefs, albumAccent: style.accent)
        let durationKey = signature.duration.map { String(format: "%.3f", $0) } ?? "-"
        let trackKey = "\(targetState.trackID ?? "-")|\(targetState.trackTitle)|\(targetState.artistName)|\(targetState.albumImageURL ?? "-")|\(document.lines.count)|duration=\(durationKey)"
        let trackChanged = trackKey != lastLASentTrack
        let lineChanged = lyrics.currentIndex != lastLineIndex
        let playChanged = targetState.isPlaying != lastLASentIsPlaying
        let artworkChanged = artworkReady != lastLAArtworkReady
        let now = Date.now
        // A style or album-color change re-renders immediately so in-app
        // appearance picks land within one tick.
        let accentChanged = targetState.albumDominantRGB != lastSentAccent
        let styleChanged = styleKey != lastAppliedStyleKey
        let playbackEventChanged = provider?.lastPlaybackChangeAt != lastAppliedPlaybackChangeAt
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
            || styleChanged || offsetChanged || anchorChanged || playbackEventChanged
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

        // Send the current line directly while the phone process is alive.
        // Keep the future schedule in the same state so the extension can
        // continue by timestamp when iOS suspends the app. Relying only on
        // TimelineView boundaries allowed the Lock Screen card to lag behind
        // widgets when iOS coalesced its timeline refreshes.
        recentLASends.removeAll { now.timeIntervalSince($0) > 60 }
        let lineSend = LiveActivityUpdatePolicy.shouldSendLineChange(
            lineChanged: lineChanged,
            timeSinceLastSend: sinceLastSend,
            sendsInLastMinute: recentLASends.count
        )
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
        if lineSend && !urgent {
            DiagnosticsLog.append(
                "la direct line update: index=\(lyrics.currentIndex.map { String($0) } ?? "-") fallback=\(targetSchedule.count)"
            )
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
            lastAppliedPlaybackChangeAt = provider?.lastPlaybackChangeAt
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
    @ObservationIgnored private var lastAppliedPlaybackChangeAt: Date?
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
            karaokeEndEpoch: karaoke.end?.timeIntervalSince1970,
            requiresUserStart: false
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

    /// Returns the Unix time at which the current playing position was zero.
    /// Widgets, Watch, and Live Activity timelines can then project playback
    /// from one common clock while the app is suspended.
    private func playbackAnchorEpoch(at date: Date) -> TimeInterval? {
        guard status?.state == .playing else { return nil }
        let position = max(0, status?.position(at: date) ?? lyrics.displayPosition)
        let rate = max(status?.rate ?? 1, 0.001)
        return date.timeIntervalSince1970 - position / rate
    }
}
