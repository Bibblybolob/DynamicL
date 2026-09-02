import Foundation
import ActivityKit
import LyricCore
import Observation
import os.log

enum LiveActivityUpdatePriority: String {
    case high
    case low
}

/// Owns the single lyrics Live Activity and applies content updates.
///
/// The activity is started ONCE per session and then only ever UPDATED —
/// track title/artist live in the updatable ContentState, so song changes
/// work from the background. (Starting a new activity is foreground-only;
/// ending + re-requesting per track killed the activity on every skip.)
@MainActor
@Observable
final class LiveActivityController {
    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "LiveActivity")
    /// Keep lyrics ahead of lower-relevance Live Activities when iOS must
    /// choose which activity receives the most prominent presentation.
    private static let relevanceScore = 1.0
    private static let dismissalKey = "liveActivityDismissedForPlaybackSession"
    private static let dismissalRecordedAtKey = "liveActivityDismissalRecordedAt"
    private static let dismissalBuildKey = "liveActivityDismissalBuild"

    private(set) var isRunning = false
    private(set) var lastErrorText: String?
    private(set) var wasDismissed: Bool
    /// The state that ActivityKit most recently reports for the current card.
    /// This is intentionally separate from the state that the app attempted
    /// to send. ActivityKit can discard an older timestamp without throwing.
    private(set) var lastAppliedState: LyricsActivityAttributes.ContentState?
    /// The app owns the local-session flag, but the controller is the first
    /// component that knows when iOS ends or dismisses an Activity. Notify the
    /// app so the next Activity can require the same explicit handoff again.
    var onActivityEnded: (() -> Void)?
    nonisolated(unsafe) private var activity: Activity<LyricsActivityAttributes>?

    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var activityStateTask: Task<Void, Never>?
    @ObservationIgnored private var contentUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pushToStartTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    private(set) var isRecovering = false
    /// ActivityKit updates are asynchronous. Coalesce a short burst and send
    /// one latest-state update at a time; overlapping update tasks were a
    /// source of silent drops that looked like a frozen Live Activity.
    @ObservationIgnored private var pendingUpdateState: LyricsActivityAttributes.ContentState?
    @ObservationIgnored private var pendingUpdatePriority: LiveActivityUpdatePriority = .low
    @ObservationIgnored private var pendingUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdateGeneration: UInt = 0
    @ObservationIgnored private var updateInFlight = false
    /// ActivityKit updates are not a real-time transport. Sending a high
    /// priority update for every item returned during a rapid skip can make
    /// iOS throttle the activity and leave the last state on screen. Keep the
    /// newest state, but leave a short interval between update calls.
    @ObservationIgnored private var lastUpdateStartedAt = Date.distantPast
    private static let minimumUrgentUpdateInterval: TimeInterval = 0.35
    /// Activity creation can be rejected while iOS changes scene state or
    /// while the simulator has no ActivityKit surface. Bound retries so the
    /// app does not turn one rejection into a start storm.
    @ObservationIgnored private var nextStartAttemptAt = Date.distantPast
    @ObservationIgnored private var startFailureCount = 0
    /// ActivityKit can reject a state with a timestamp older than the state
    /// already displayed. Keep a process-local monotonic floor, including
    /// when the controller sends a coalesced update after a short delay.
    @ObservationIgnored private var lastSentTimestamp = Date.distantPast
    /// Push-to-start tokens are per-attributes-type, not per-activity — one
    /// stream for the whole process lifetime.
    nonisolated(unsafe) private static var pushToStartStreamStarted = false

    init() {
        let defaults = UserDefaults.standard
        let storedDismissal = defaults.bool(forKey: Self.dismissalKey)
        let hasRecordedDate = defaults.object(forKey: Self.dismissalRecordedAtKey) != nil
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let dismissalBuild = defaults.string(forKey: Self.dismissalBuildKey)
        // A dismissal is scoped to one playback session in one installed
        // build. TestFlight can replace the app while an old ActivityKit card
        // is being removed. Do not carry that old card's dismissal into the
        // new build and block every later start.
        let staleDismissal = storedDismissal && (
            !hasRecordedDate
                || dismissalBuild == nil
                || dismissalBuild != currentBuild
        )
        wasDismissed = storedDismissal && !staleDismissal
        if staleDismissal {
            defaults.set(false, forKey: Self.dismissalKey)
            defaults.removeObject(forKey: Self.dismissalRecordedAtKey)
            defaults.removeObject(forKey: Self.dismissalBuildKey)
            DiagnosticsLog.append("cleared stale Live Activity dismissal")
        }
        // Push-to-start tokens are available before the first activity exists.
        // Start observing them for the process lifetime so the server can
        // remotely start the first activity when that path is enabled.
        beginPushToStartTokenStreaming()
        adoptExistingActivityIfNeeded()
    }

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// True when the adopted or current activity is still showing the
    /// first-use action. This lets the app recover a real activity after a
    /// process relaunch without making the user press Show Lyrics again.
    var requiresUserStart: Bool {
        activity?.content.state.requiresUserStart == true
    }

    /// True while the current card still shows a temporary loading message
    /// for this track. AppModel uses this acknowledgement to retry the final
    /// lyric payload instead of assuming that an awaited update was visible.
    var isShowingLoadingPlaceholder: Bool {
        guard let state = activity?.content.state ?? lastAppliedState else {
            return false
        }
        // A placeholder from either the current or previous track must be
        // replaced. Restricting this check to matching track IDs could strand
        // an old loading card after a rapid skip.
        return LiveActivityUpdatePolicy.isLoadingPlaceholder(state.currentLine)
    }

    /// Stable ActivityKit identity used to bind the explicit first-use
    /// handoff to the card that the user actually pressed.
    var activityID: String? {
        if let activityID = activity?.id {
            return activityID
        }
        // ActivityKit can expose a surviving Activity before the controller's
        // adoption path finishes during a cold launch. Return that identity so
        // a queued Show Lyrics action is not consumed as an unbound request.
        return Activity<LyricsActivityAttributes>.activities.first(where: {
            $0.activityState != .ended && $0.activityState != .dismissed
        })?.id
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
        let now = Date.now
        guard now >= nextStartAttemptAt else { return }
        guard isEnabled else {
            lastErrorText = "Live Activities disabled in Settings"
            nextStartAttemptAt = now.addingTimeInterval(30)
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
            startFailureCount = 0
            nextStartAttemptAt = .distantPast
            update(state: state)
            return
        }
        // Adoption can discover a dismissed Activity. Re-check after adoption
        // because the initial guard ran before the platform activity list was
        // inspected. A dismissed Activity must not be replaced in the same
        // call or a manual dismissal would lose its session-level protection.
        guard !wasDismissed else {
            DiagnosticsLog.append("LA start suppressed after discovered dismissal")
            return
        }

        // No survivor to adopt: create fresh. When called from the background
        // iOS may throw — caught below; the next tick tries again.
        let attributes = LyricsActivityAttributes()
        let content = ActivityContent(
            state: state.compacted(),
            staleDate: staleDate(for: state),
            relevanceScore: Self.relevanceScore
        )
        do {
            let created: Activity<LyricsActivityAttributes>
            do {
                created = try Activity.request(
                    attributes: attributes,
                    // Server-push path: with a token, our sync server can
                    // update or end this activity while the app is suspended.
                    content: content,
                    pushType: .token
                )
            } catch {
                // A local Lock Screen card is still useful when APNs token
                // creation is temporarily unavailable. Dynamic Lyrics follows
                // the same local-first pattern: create the Activity now, then
                // connect its background update path separately.
                DiagnosticsLog.append("LA token request failed; trying local activity")
                created = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            }
            activity = created
            isRunning = true
            recordApplied(created.content.state)
            lastErrorText = nil
            startFailureCount = 0
            nextStartAttemptAt = .distantPast
            Self.log.info("activity started ok")
            DiagnosticsLog.append("LA started: \(state.trackTitle) play=\(state.isPlaying)")
            if state.requiresUserStart != true {
                SharedNowPlaying.markLiveActivityFirstUseCompleted(for: created.id)
            }
            beginActivityStateMonitoring(for: created)
            beginPushTokenStreaming()
        } catch {
            lastErrorText = "request failed: \(error.localizedDescription)"
            Self.log.error("request failed: \(error.localizedDescription)")
            activity = nil
            isRunning = false
            startFailureCount = min(startFailureCount + 1, 5)
            let retryDelays: [TimeInterval] = [2, 4, 8, 16, 30]
            nextStartAttemptAt = Date.now.addingTimeInterval(
                retryDelays[startFailureCount - 1]
            )
        }
    }

    /// Replaces a Live Activity that ActivityKit still reports as active even
    /// when no card is visible. This is used only by an explicit in-app
    /// recovery action. Automatic playback detection continues to adopt and
    /// update an existing activity so it does not create duplicates.
    func restartForRecovery(state: LyricsActivityAttributes.ContentState) {
        allowRecoveryStart(reason: "Start or Restart Lock Screen Lyrics")

        // Repeated taps must not create overlapping end/request tasks. Those
        // tasks can end each other's replacement Activity and leave iOS with
        // no visible card even though the last request succeeded.
        guard !isRecovering else {
            DiagnosticsLog.append("LA restart ignored: recovery already in progress")
            return
        }

        guard let existing = activity else {
            start(state: state)
            return
        }

        nonisolated(unsafe) let ending = existing
        pushTokenTask?.cancel()
        pushTokenTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
        pendingUpdateGeneration &+= 1
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingUpdateState = nil
        activity = nil
        isRunning = false
        isRecovering = true
        lastSentTimestamp = .distantPast
        lastAppliedState = nil
        DiagnosticsLog.append("LA explicit restart requested")

        recoveryTask = Task { @MainActor [weak self] in
            await ending.end(nil, dismissalPolicy: .immediate)
            do {
                // Give ActivityKit time to publish the old activity's terminal
                // state before requesting its replacement.
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.allowRecoveryStart(reason: "Activity replacement")
            self.start(state: state)
            self.isRecovering = false
            self.recoveryTask = nil
        }
    }

    func update(
        state: LyricsActivityAttributes.ContentState,
        priority: LiveActivityUpdatePriority = .low
    ) {
        guard let activity else {
            start(state: state)
            return
        }

        // A stale reference can survive after the system ends or dismisses an
        // activity. Treat it as a new session so later lyric changes are not
        // queued forever against a dead Activity object.
        switch activity.activityState {
        case .ended:
            handleActivityEnded(id: activity.id, dismissed: false)
            start(state: state)
            return
        case .dismissed:
            handleActivityEnded(id: activity.id, dismissed: true)
            return
        default:
            break
        }

        pendingUpdateState = state.compacted()
        if priority == .high {
            pendingUpdatePriority = .high
            pendingUpdateGeneration &+= 1
            // Do not cancel an ActivityKit call already in flight. Queue the
            // urgent state behind it and send it immediately after completion.
            if !updateInFlight {
                pendingUpdateTask?.cancel()
                pendingUpdateTask = nil
                schedulePendingUpdate()
            }
            return
        }

        if pendingUpdatePriority != .high {
            pendingUpdatePriority = .low
        }
        schedulePendingUpdate()
    }

    /// Starts the next pending update. High-priority states are coalesced to
    /// the newest state and are rate limited to protect ActivityKit from a
    /// rapid skip storm; low-priority states are coalesced for 80 ms.
    private func schedulePendingUpdate() {
        guard !updateInFlight, pendingUpdateTask == nil, pendingUpdateState != nil else { return }
        pendingUpdateGeneration &+= 1
        let generation = pendingUpdateGeneration
        let priority = pendingUpdatePriority
        pendingUpdateTask = Task { [weak self] in
            let delayMilliseconds: Int
            if priority == .low {
                delayMilliseconds = 80
            } else if let self {
                let nextAllowed = self.lastUpdateStartedAt
                    .addingTimeInterval(Self.minimumUrgentUpdateInterval)
                let wait = max(0, nextAllowed.timeIntervalSinceNow)
                delayMilliseconds = Int(ceil(wait * 1_000))
            } else {
                delayMilliseconds = 0
            }
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    self?.finishCancelledUpdate(generation: generation)
                    return
                }
                guard !Task.isCancelled else {
                    self?.finishCancelledUpdate(generation: generation)
                    return
                }
            }
            await self?.flushPendingUpdate(generation: generation)
        }
    }

    /// Cancels a coalesced update before an urgent user action or track
    /// transition. Without this barrier, a stale delayed state can arrive
    /// after a fresh pause, skip, or seek state and make the activity look
    /// frozen again.
    func interruptPendingUpdates(reason: String) {
        pendingUpdateGeneration &+= 1
        if !updateInFlight {
            pendingUpdateTask?.cancel()
            pendingUpdateTask = nil
        }
        pendingUpdateState = nil
        pendingUpdatePriority = .low
        DiagnosticsLog.append("LA update interrupted: \(reason)")
    }

    private func finishCancelledUpdate(generation: UInt) {
        guard generation == pendingUpdateGeneration else { return }
        pendingUpdateTask = nil
    }

    private func flushPendingUpdate(generation: UInt) async {
        guard generation == pendingUpdateGeneration else { return }
        guard let state = pendingUpdateState, let activity else {
            pendingUpdateState = nil
            pendingUpdateTask = nil
            return
        }
        let priority = pendingUpdatePriority
        pendingUpdateState = nil
        // The priority belongs to the state we are sending, not to the
        // controller forever. A later scheduled batch must return to the low
        // priority/coalesced path after an urgent play, pause, skip, or seek.
        // If a new urgent state arrives while this await is in flight, its
        // update() call writes .high again before the next flush.
        pendingUpdatePriority = .low
        updateInFlight = true

        // Keep both ActivityKit's timestamp and the encoded field monotonic.
        // This prevents a server/phone handoff or a delayed task from being
        // discarded as an older update.
        var sentState = state
        let requestedTimestamp = state.generatedAtEpoch.map(Date.init(timeIntervalSince1970:)) ?? .now
        let timestamp = max(
            requestedTimestamp,
            lastSentTimestamp.addingTimeInterval(0.001)
        )
        sentState.generatedAtEpoch = timestamp.timeIntervalSince1970
        lastSentTimestamp = timestamp

        // Stale-date honesty: while playing, mark the content stale well past
        // the worst-case poll gap (12s request ceiling + margin) so a stalled
        // feed decays visibly instead of freezing on a lie. Paused content
        // never goes stale.
        let staleDate = staleDate(for: sentState)
        nonisolated(unsafe) let ref = activity
        nonisolated(unsafe) let content = ActivityContent(
            state: sentState,
            staleDate: staleDate,
            relevanceScore: Self.relevanceScore
        )
        let schedule = sentState.resolvedScheduledLines
        let horizon = schedule.last.map { max(0, $0.date.timeIntervalSinceNow) }
        let artworkCache = sentState.albumImageURL.map {
            ArtworkFileCache.data(for: $0) == nil ? "miss" : "hit"
        } ?? "none"
        let summary = "\(sentState.trackTitle) play=\(sentState.isPlaying) source=\(sentState.source?.rawValue ?? "legacy") rev=\(sentState.revision ?? -1) bytes=\(sentState.encodedSize) schedule=\(schedule.count) horizon=\(horizon.map { String(format: "%.1f", $0) } ?? "-")s artCache=\(artworkCache)"
        lastUpdateStartedAt = .now
        if #available(iOS 17.2, *) {
            await ref.update(content, timestamp: timestamp)
        } else {
            await ref.update(content)
        }
        // Read ActivityKit's canonical state after the await. This is the
        // acknowledgement used by the placeholder recovery path. It also
        // raises the timestamp floor if a server push won the race.
        recordApplied(ref.content.state)
        updateInFlight = false
        // A new event may have arrived while ActivityKit processed the old
        // state. Do not clear or overwrite the newer pending state.
        guard generation == pendingUpdateGeneration else {
            pendingUpdateTask = nil
            schedulePendingUpdate()
            return
        }

        DiagnosticsLog.append("LA sent: \(summary) priority=\(priority.rawValue)")

        pendingUpdateTask = nil
        if pendingUpdateState != nil {
            schedulePendingUpdate()
        }
    }

    /// Streams per-activity update tokens + the global push-to-start token
    /// into the sync server. Tokens arrive once shortly after request and
    /// again on any rotation; each change is logged (so the raw APNs pipeline
    /// can be exercised manually) and uploaded to the managed sync server.
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
        let candidates = Activity<LyricsActivityAttributes>.activities
        // ActivityKit can retain a dismissed activity in its activity list
        // during relaunch or after TestFlight replaces the app. Prefer a
        // still-live activity when one exists. A historical dismissed record
        // is not proof that the user dismissed the current playback session;
        // only the monitored state transition records that suppression.
        guard let survivor = candidates.first(where: {
            $0.activityState != .dismissed && $0.activityState != .ended
        }) else {
            if candidates.contains(where: { $0.activityState == .dismissed }) {
                DiagnosticsLog.append("ignored historical dismissed live activity")
            }
            return false
        }

        nonisolated(unsafe) let found = survivor
        activity = found
        isRunning = true
        recordApplied(found.content.state)
        if found.content.state.requiresUserStart != true {
            SharedNowPlaying.markLiveActivityFirstUseCompleted(for: found.id)
        }
        setDismissed(false)
        beginActivityStateMonitoring(for: found)
        beginPushTokenStreaming()
        Self.log.info("adopted existing live activity")
        DiagnosticsLog.append("adopted existing live activity")

        for candidate in candidates where candidate.id != survivor.id {
            guard candidate.activityState != .dismissed,
                  candidate.activityState != .ended else { continue }
            nonisolated(unsafe) let stale = candidate
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        return true
    }

    private func beginActivityStateMonitoring(for current: Activity<LyricsActivityAttributes>) {
        activityStateTask?.cancel()
        contentUpdateTask?.cancel()
        nonisolated(unsafe) let observed = current
        activityStateTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                switch state {
                case .stale:
                    DiagnosticsLog.append("LA state became stale")
                case .ended, .dismissed:
                    self?.handleActivityEnded(id: observed.id, dismissed: state == .dismissed)
                    return
                default:
                    break
                }
            }
        }
        contentUpdateTask = Task { [weak self] in
            for await content in observed.contentUpdates {
                let state = content.state
                self?.recordApplied(state)
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
        pendingUpdateGeneration &+= 1
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingUpdateState = nil
        activity = nil
        isRunning = false
        lastSentTimestamp = .distantPast
        lastAppliedState = nil
        setDismissed(dismissed)
        SharedNowPlaying.resetLiveActivityFirstUse()
        SyncServerClient.shared.resetFirstUseGate()
        onActivityEnded?()
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
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        guard let activity else {
            // The server can own an activity while this process is suspended
            // or before it has adopted the remote Activity object. Still
            // clear the local dismissal marker and tell the server to remove
            // its APNs route when the user disables the feature.
            setDismissed(false)
            SharedNowPlaying.resetLiveActivityFirstUse()
            SyncServerClient.shared.resetFirstUseGate()
            lastAppliedState = nil
            lastSentTimestamp = .distantPast
            onActivityEnded?()
            SyncServerClient.shared.noteActivityEnded(dismissed: false)
            return
        }
        nonisolated(unsafe) let ending = activity
        pushTokenTask?.cancel()
        pushTokenTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
        pendingUpdateGeneration &+= 1
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingUpdateState = nil
        Task { @MainActor in
            await ending.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        isRunning = false
        lastSentTimestamp = .distantPast
        lastAppliedState = nil
        setDismissed(false)
        SharedNowPlaying.resetLiveActivityFirstUse()
        SyncServerClient.shared.resetFirstUseGate()
        onActivityEnded?()
        SyncServerClient.shared.noteActivityEnded(dismissed: false)
    }

    /// Records the state that ActivityKit exposes, including remote APNs
    /// updates. A later phone update must use a timestamp above this floor or
    /// iOS can keep the server state and silently discard the phone state.
    private func recordApplied(_ state: LyricsActivityAttributes.ContentState) {
        lastAppliedState = state
        guard let epoch = state.generatedAtEpoch, epoch.isFinite else { return }
        lastSentTimestamp = max(
            lastSentTimestamp,
            Date(timeIntervalSince1970: epoch)
        )
    }

    /// Keeps a user dismissal in force through track changes. A confirmed new
    /// playback session calls `resetDismissalForNewPlaybackSession()`.
    func suppressForCurrentPlaybackSession() {
        // AppModel evaluates this guard on every ticker pass while the server
        // remembers the dismissal. Repeating the end notification can create
        // a heartbeat storm and make a dismissed activity look like a retry
        // loop. One suppression is enough until a new playback session is
        // confirmed.
        guard isRunning || !wasDismissed else { return }
        if isRunning { end() }
        setDismissed(true)
        // The server already supplied this dismissal. The next heartbeat will
        // confirm local state. Reporting a second synthetic user dismissal
        // here created a self-sustaining end/dismiss loop.
        DiagnosticsLog.append("LA suppressed by server dismissal")
    }

    func resetDismissalForNewPlaybackSession() {
        guard wasDismissed else { return }
        setDismissed(false)
        DiagnosticsLog.append("LA dismissal reset for new playback session")
    }

    /// Clears a stale dismissal or start backoff after a direct user recovery
    /// action. A TestFlight install can leave a dismissed ActivityKit record
    /// from the previous build. Without this explicit reset, the recovery
    /// button can activate polling but every Activity request remains blocked.
    func allowRecoveryStart(reason: String) {
        let hadSuppression = wasDismissed
        setDismissed(false)
        startFailureCount = 0
        nextStartAttemptAt = .distantPast
        lastErrorText = nil
        if hadSuppression {
            DiagnosticsLog.append("LA dismissal cleared by \(reason)")
        }
    }

    private func setDismissed(_ value: Bool) {
        wasDismissed = value
        UserDefaults.standard.set(value, forKey: Self.dismissalKey)
        if value {
            UserDefaults.standard.set(
                Date.now.timeIntervalSince1970,
                forKey: Self.dismissalRecordedAtKey
            )
            UserDefaults.standard.set(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                forKey: Self.dismissalBuildKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: Self.dismissalRecordedAtKey)
            UserDefaults.standard.removeObject(forKey: Self.dismissalBuildKey)
        }
    }

    private func staleDate(for state: LyricsActivityAttributes.ContentState) -> Date? {
        guard state.isPlaying else { return nil }
        let minimum = Date.now.addingTimeInterval(60)
        // The schedule horizon is the end of the last interval, not its
        // onset. Using the onset can mark a long final lyric stale while that
        // lyric is still valid on the Lock Screen.
        guard let last = state.resolvedScheduledLines.last else { return minimum }
        let horizon = last.endDate ?? last.date
        return max(minimum, horizon.addingTimeInterval(15))
    }
}
