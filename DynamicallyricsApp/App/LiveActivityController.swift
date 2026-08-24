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

        // End any activities left over from previous sessions/installs —
        // they survive process restarts and otherwise pile up frozen on the
        // Lock Screen forever.
        let orphans = Activity<LyricsActivityAttributes>.activities
        if !orphans.isEmpty {
            Self.log.info("ending \(orphans.count) orphaned activity(ies)")
            DiagnosticsLog.append("ending \(orphans.count) orphaned live activity(ies)")
            for orphan in orphans {
                nonisolated(unsafe) let stale = orphan
                Task { await stale.end(dismissalPolicy: .immediate) }
            }
        }

        let attributes = LyricsActivityAttributes()
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            isRunning = true
            lastErrorText = nil
            Self.log.info("activity started ok")
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
        nonisolated(unsafe) let content = ActivityContent(state: state, staleDate: nil)
        Task { @MainActor in
            try? await ref.update(content)
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
