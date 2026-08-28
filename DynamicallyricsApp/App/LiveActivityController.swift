import Foundation
import ActivityKit
import LyricCore
import os.log

/// Owns the single lyrics Live Activity and applies content updates.
///
/// The activity is started ONCE per session and then only ever UPDATED —
/// track title/artist live in the updatable ContentState, so song changes
/// work from the background. (Starting a new activity is foreground-only;
/// ending + re-requesting per track killed the activity on every skip.)
@MainActor
final class LiveActivityController {
    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "LiveActivity")
    private static let dismissalKey = "liveActivityDismissedForPlaybackSession"

    private(set) var isRunning = false
    private(set) var lastErrorText: String?
    private(set) var wasDismissed: Bool
    nonisolated(unsafe) private var activity: Activity<LyricsActivityAttributes>?

    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var activityStateTask: Task<Void, Never>?
    @ObservationIgnored private var contentUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pushToStartTask: Task<Void, Never>?
    /// ActivityKit updates are asynchronous. Coalesce a short burst and send
    /// one latest-state update at a time; overlapping update tasks were a
    /// source of silent drops that looked like a frozen Live Activity.
    @ObservationIgnored private var pendingUpdateState: LyricsActivityAttributes.ContentState?
    @ObservationIgnored private var pendingUpdateTask: Task<Void, Never>?
    /// Push-to-start tokens are per-attributes-type, not per-activity — one
    /// stream for the whole process lifetime.
    nonisolated(unsafe) private static var pushToStartStreamStarted = false

    init() {
        wasDismissed = UserDefaults.standard.bool(forKey: Self.dismissalKey)
        // Push-to-start tokens are available before the first activity exists.
        // Start observing them for the process lifetime so the server can
        // remotely start the first activity when that path is enabled.
        beginPushToStartTokenStreaming()
        adoptExistingActivityIfNeeded()
    }

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var syncActivityState: SyncActivityState {
        if isRunning { return .active }
        return wasDismissed ? .dismissed : .none
    }

    func start(state: LyricsActivityAttributes.ContentState) {
        Self.log.info("start requested, enabled=\(self.isEnabled)")
        guard !wasDismissed else {
            DiagnosticsLog.append("LA start suppressed after user dismissal")
            return
        }
        guard isEnabled else {
            lastErrorText = "Live Activities disabled in Settings"
            return
        }
        guard !isRunning else {
            update(state: state)
            return
        }
        setDismissed(false)

        // Adopt an activity left over from a previous session/relaunch when
        // possible: updating works from the background, creating doesn't. Any
        // OTHER leftovers get ended so they don't pile up frozen.
        if adoptExistingActivityIfNeeded() {
            update(state: state)
            return
        }

        // No survivor to adopt: create fresh. When called from the background
        // iOS may throw — caught below; the next tick tries again.
        let attributes = LyricsActivityAttributes()
        do {
            let created = try Activity.request(
                attributes: attributes,
                // Stale-date honesty: mark playing content stale well past the
                // worst-case poll gap (12s timeout + margin). Living permanently
                // inside an 8s stale window made the system deprioritize renders.
                content: .init(state: state.compacted(), staleDate: staleDate(for: state)),
                // Server-push path: with a token, our sync server can update
                // or end this activity over APNs even when the app is dead.
                pushType: .token
            )
            activity = created
            isRunning = true
            lastErrorText = nil
            Self.log.info("activity started ok")
            DiagnosticsLog.append("LA started: \(state.trackTitle) play=\(state.isPlaying)")
            beginActivityStateMonitoring(for: created)
            beginPushTokenStreaming()
        } catch {
            lastErrorText = "request failed: \(error.localizedDescription)"
            Self.log.error("request failed: \(error.localizedDescription)")
            activity = nil
            isRunning = false
        }
    }

    func update(state: LyricsActivityAttributes.ContentState) {
        guard activity != nil else {
            start(state: state)
            return
        }
        pendingUpdateState = state.compacted()
        guard pendingUpdateTask == nil else { return }

        // A tiny debounce lets a track/playing/style transition settle into
        // one payload while keeping ordinary lyric changes effectively
        // immediate. The controller never has more than one ActivityKit call
        // in flight.
        pendingUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.flushPendingUpdate()
        }
    }

    private func flushPendingUpdate() async {
        guard let state = pendingUpdateState, let activity else {
            pendingUpdateState = nil
            pendingUpdateTask = nil
            return
        }
        pendingUpdateState = nil

        // Stale-date honesty: while playing, mark the content stale well past
        // the worst-case poll gap (12s request ceiling + margin) so a stalled
        // feed decays visibly instead of freezing on a lie. Paused content
        // never goes stale.
        let staleDate = staleDate(for: state)
        nonisolated(unsafe) let ref = activity
        nonisolated(unsafe) let content = ActivityContent(state: state, staleDate: staleDate)
        let schedule = state.resolvedScheduledLines
        let horizon = schedule.last.map { max(0, $0.date.timeIntervalSinceNow) }
        let artworkCache = state.albumImageURL.map {
            SharedNowPlaying.cachedArtwork(for: $0) == nil ? "miss" : "hit"
        } ?? "none"
        let summary = "\(state.trackTitle) play=\(state.isPlaying) source=\(state.source?.rawValue ?? "legacy") rev=\(state.revision ?? -1) bytes=\(state.encodedSize) schedule=\(schedule.count) horizon=\(horizon.map { String(format: "%.1f", $0) } ?? "-")s artCache=\(artworkCache)"
        if #available(iOS 17.2, *) {
            let generatedAt = state.generatedAtEpoch.map(Date.init(timeIntervalSince1970:)) ?? .now
            await ref.update(content, timestamp: generatedAt)
        } else {
            await ref.update(content)
        }
        DiagnosticsLog.append("LA sent: \(summary)")

        pendingUpdateTask = nil
        if let pending = pendingUpdateState {
            update(state: pending)
        }
    }

    /// Streams per-activity update tokens + the global push-to-start token
    /// into the sync server. Tokens arrive once shortly after request and
    /// again on any rotation; each change is logged (so the raw APNs pipeline
    /// can be exercised manually) and uploaded when a server URL is set.
    private func beginPushTokenStreaming() {
        guard let activity else { return }
        beginPushToStartTokenStreaming()
        pushTokenTask?.cancel()
        nonisolated(unsafe) let current = activity
        pushTokenTask = Task { [weak self] in
            for await data in current.pushTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await self?.record(updateToken: hex)
            }
        }

    }

    /// A remote start can launch the process before Spotify or lyrics load.
    /// Adopt it during controller initialization so its update token reaches
    /// the server immediately.
    @discardableResult
    private func adoptExistingActivityIfNeeded() -> Bool {
        if isRunning { return true }
        var adopted = false
        for candidate in Activity<LyricsActivityAttributes>.activities {
            if !adopted {
                nonisolated(unsafe) let found = candidate
                activity = found
                isRunning = true
                setDismissed(false)
                beginActivityStateMonitoring(for: found)
                beginPushTokenStreaming()
                adopted = true
                Self.log.info("adopted existing live activity")
                DiagnosticsLog.append("adopted existing live activity")
            } else {
                nonisolated(unsafe) let stale = candidate
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
        }
        return adopted
    }

    private func beginActivityStateMonitoring(for current: Activity<LyricsActivityAttributes>) {
        activityStateTask?.cancel()
        contentUpdateTask?.cancel()
        nonisolated(unsafe) let observed = current
        activityStateTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self?.handleActivityEnded(id: observed.id, dismissed: state == .dismissed)
                break
            }
        }
        contentUpdateTask = Task {
            for await content in observed.contentUpdates {
                let state = content.state
                let delay = state.generatedAtEpoch.map {
                    max(0, Date.now.timeIntervalSince1970 - $0)
                }
                DiagnosticsLog.append(
                    "LA applied: source=\(state.source?.rawValue ?? "legacy") rev=\(state.revision ?? -1) delay=\(delay.map { String(format: "%.2f", $0) } ?? "-")s schedule=\(state.resolvedScheduledLines.count) art=\(state.albumImageURL != nil)"
                )
            }
        }
    }

    private func handleActivityEnded(id: String, dismissed: Bool) {
        guard activity?.id == id else { return }
        pushTokenTask?.cancel()
        pushTokenTask = nil
        activityStateTask = nil
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingUpdateState = nil
        activity = nil
        isRunning = false
        setDismissed(dismissed)
        SyncServerClient.shared.noteActivityEnded(dismissed: dismissed)
        DiagnosticsLog.append(dismissed ? "LA dismissed by user" : "LA ended externally")
    }

    private func beginPushToStartTokenStreaming() {
        guard !Self.pushToStartStreamStarted, #available(iOS 17.2, *) else { return }
        Self.pushToStartStreamStarted = true
        pushToStartTask = Task { [weak self] in
            if let existing = Activity<LyricsActivityAttributes>.pushToStartToken {
                let hex = existing.map { String(format: "%02x", $0) }.joined()
                await self?.record(pushToStartToken: hex)
            }
            for await data in Activity<LyricsActivityAttributes>.pushToStartTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await self?.record(pushToStartToken: hex)
            }
        }
    }

    private func record(updateToken: String? = nil, pushToStartToken: String? = nil) async {
        await SyncServerClient.shared.record(
            updateToken: updateToken,
            pushToStartToken: pushToStartToken
        )
    }

    func end() {
        guard let activity else { return }
        nonisolated(unsafe) let ending = activity
        pushTokenTask?.cancel()
        pushTokenTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingUpdateState = nil
        Task { @MainActor in
            await ending.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        isRunning = false
        setDismissed(false)
        SyncServerClient.shared.noteActivityEnded(dismissed: false)
    }

    /// Keeps a user dismissal in force through track changes. A confirmed new
    /// playback session calls `resetDismissalForNewPlaybackSession()`.
    func suppressForCurrentPlaybackSession() {
        if isRunning { end() }
        setDismissed(true)
        SyncServerClient.shared.noteActivityEnded(dismissed: true)
    }

    func resetDismissalForNewPlaybackSession() {
        guard wasDismissed else { return }
        setDismissed(false)
        DiagnosticsLog.append("LA dismissal reset for new playback session")
    }

    private func setDismissed(_ value: Bool) {
        wasDismissed = value
        UserDefaults.standard.set(value, forKey: Self.dismissalKey)
    }

    private func staleDate(for state: LyricsActivityAttributes.ContentState) -> Date? {
        guard state.isPlaying else { return nil }
        let minimum = Date.now.addingTimeInterval(60)
        guard let last = state.resolvedScheduledLines.last?.date else { return minimum }
        return max(minimum, last.addingTimeInterval(15))
    }
}
