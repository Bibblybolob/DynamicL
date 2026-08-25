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

    private(set) var isRunning = false
    private(set) var lastErrorText: String?
    nonisolated(unsafe) private var activity: Activity<LyricsActivityAttributes>?

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(state: LyricsActivityAttributes.ContentState) {
        Self.log.info("start requested, enabled=\(self.isEnabled)")
        guard isEnabled else {
            lastErrorText = "Live Activities disabled in Settings"
            return
        }
        guard !isRunning else {
            update(state: state)
            return
        }

        // Adopt an activity left over from a previous session/relaunch when
        // possible: updating works from the background, creating doesn't. Any
        // OTHER leftovers get ended so they don't pile up frozen.
        var adopted = false
        let orphans = Activity<LyricsActivityAttributes>.activities
        for orphan in orphans {
            if !adopted {
                nonisolated(unsafe) let found = orphan
                activity = found
                isRunning = true
                adopted = true
                Self.log.info("adopted existing live activity")
                DiagnosticsLog.append("adopted existing live activity")
            } else {
                nonisolated(unsafe) let stale = orphan
                Task { await stale.end(dismissalPolicy: .immediate) }
            }
        }
        if adopted {
            update(state: state)
            return
        }

        // No survivor to adopt: create fresh. When called from the background
        // iOS may throw — caught below; the next tick tries again.
        let attributes = LyricsActivityAttributes()
        do {
            activity = try Activity.request(
                attributes: attributes,
                // Stale-date honesty: mark playing content stale well past the
                // worst-case poll gap (12s timeout + margin). Living permanently
                // inside an 8s stale window made the system deprioritize renders.
                content: .init(state: state, staleDate: state.isPlaying ? .now.addingTimeInterval(30) : nil)
            )
            isRunning = true
            lastErrorText = nil
            Self.log.info("activity started ok")
            DiagnosticsLog.append("LA started: \(state.trackTitle) play=\(state.isPlaying)")
        } catch {
            lastErrorText = "request failed: \(error.localizedDescription)"
            Self.log.error("request failed: \(error.localizedDescription)")
            activity = nil
            isRunning = false
        }
    }

    func update(state: LyricsActivityAttributes.ContentState) {
        guard let activity else {
            start(state: state)
            return
        }
        nonisolated(unsafe) let ref = activity
        // Stale-date honesty: while playing, mark the content stale well past
        // the worst-case poll gap (12s request ceiling + margin) so a stalled
        // feed decays visibly instead of freezing on a lie. Paused content
        // never goes stale.
        let staleDate: Date? = state.isPlaying ? .now.addingTimeInterval(30) : nil
        nonisolated(unsafe) let content = ActivityContent(state: state, staleDate: staleDate)
        let summary = "\(state.trackTitle) play=\(state.isPlaying) anchors=\(state.progressStart != nil && state.progressEnd != nil) frozen=\(state.frozenProgress.map { String(format: "%.2f", $0) } ?? "-")"
        Task { @MainActor in
            // NOTE: this update(_:) overload cannot throw — ActivityKit swallows
            // throttling/drop failures silently, which is exactly why the
            // reconciliation self-heal exists.
            await ref.update(content)
            DiagnosticsLog.append("LA sent: \(summary)")
        }
    }

    func end() {
        guard let activity else { return }
        nonisolated(unsafe) let ending = activity
        Task { @MainActor in
            await ending.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        isRunning = false
    }
}
