import Foundation
import ActivityKit
import LyricCore
import os.log

/// Owns the single lyrics Live Activity and applies content updates on line changes.
@MainActor
final class LiveActivityController {
    private static let log = Logger(subsystem: "com.jonathantran.dynamicallyrics", category: "LiveActivity")

    private(set) var isRunning = false
    private(set) var lastErrorText: String?
    nonisolated(unsafe) private var activity: Activity<LyricsActivityAttributes>?
    private(set) var currentTrackKey: String?

    /// ActivityKit attributes are immutable per activity, so the track key is how
    /// callers detect that the current activity shows stale title/artist and must
    /// be ended and restarted.
    static func trackKey(for track: TrackSignature) -> String {
        "\(track.title)|\(track.artist)"
    }

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(track: TrackSignature, state: LyricsActivityAttributes.ContentState) {
        Self.log.info("start requested, enabled=\(self.isEnabled)")
        guard isEnabled else {
            lastErrorText = "Live Activities disabled in Settings"
            return
        }
        let key = Self.trackKey(for: track)
        if isRunning, currentTrackKey != key {
            end()
        }
        guard !isRunning else { return }

        let attributes = LyricsActivityAttributes(trackTitle: track.title, artistName: track.artist)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            currentTrackKey = key
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
        guard let activity else { return }
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
        currentTrackKey = nil
        isRunning = false
    }
}
