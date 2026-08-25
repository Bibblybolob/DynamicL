#if os(iOS)
import ActivityKit
import Foundation

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var trackTitle: String
        public var artistName: String
        public var currentLine: String
        public var nextLine: String?
        public var isPlaying: Bool
        /// Wall-clock anchors for a self-advancing ProgressView(timerInterval:) —
        /// the system animates the bar between app updates. Nil on legacy states.
        public var progressStart: Date?
        public var progressEnd: Date?
        /// Static bar fraction used while paused (intervals would keep advancing).
        public var frozenProgress: Double?

        public init(trackTitle: String, artistName: String, currentLine: String,
                    nextLine: String? = nil, isPlaying: Bool,
                    progressStart: Date? = nil, progressEnd: Date? = nil,
                    frozenProgress: Double? = nil) {
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
            self.progressStart = progressStart
            self.progressEnd = progressEnd
            self.frozenProgress = frozenProgress
        }
    }

    /// Static payload — kept for compatibility but no longer carries the track,
    /// so a song change never requires tearing the activity down.
    public var sessionID: String

    public init(sessionID: String = "lyrics") {
        self.sessionID = sessionID
    }

    @available(*, deprecated, message: "Use sessionID init; track info lives in ContentState now.")
    public init(trackTitle: String, artistName: String) {
        self.sessionID = "lyrics"
    }
}
#endif
