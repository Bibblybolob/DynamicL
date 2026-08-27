#if os(iOS)
import ActivityKit
import Foundation

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var trackTitle: String
        public var artistName: String
        /// Artwork URL used by the mini-player presentation. The view falls
        /// back to a record placeholder when the extension cannot load it.
        public var albumImageURL: String?
        public var currentLine: String
        public var nextLine: String?
        public var isPlaying: Bool
        /// Wall-clock anchors for a self-advancing ProgressView(timerInterval:) —
        /// the system animates the bar between app updates. Nil on legacy states.
        public var progressStart: Date?
        public var progressEnd: Date?
        /// Static bar fraction used while paused (intervals would keep advancing).
        public var frozenProgress: Double?
        /// Future lyric lines with wall-clock dates. The Live Activity uses
        /// these to advance locally on the same playback clock as the app,
        /// rather than waiting for a separate ActivityKit update per line.
        /// Optional so activities created by older builds still decode.
        public var scheduledLines: [WidgetLyricSnapshot.ScheduledLine]?
        /// Wall-clock interval for the active lyric. The Live Activity uses
        /// this to paint a local karaoke sweep without receiving an update for
        /// every animation frame.
        public var karaokeStartDate: Date?
        public var karaokeEndDate: Date?
        /// Static progress used while playback is paused.
        public var frozenKaraokeProgress: Double?
        /// Dominant album-art color as [r, g, b] in 0...1 — drives Album-mode
        /// theming. Nil-safe so legacy states keep decoding.
        public var albumDominantRGB: [Double]?

        public init(trackTitle: String, artistName: String, albumImageURL: String? = nil,
                    currentLine: String,
                    nextLine: String? = nil, isPlaying: Bool,
                    progressStart: Date? = nil, progressEnd: Date? = nil,
                    frozenProgress: Double? = nil,
                    scheduledLines: [WidgetLyricSnapshot.ScheduledLine]? = nil,
                    karaokeStartDate: Date? = nil,
                    karaokeEndDate: Date? = nil,
                    frozenKaraokeProgress: Double? = nil,
                    albumDominantRGB: [Double]? = nil) {
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.albumImageURL = albumImageURL
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
            self.progressStart = progressStart
            self.progressEnd = progressEnd
            self.frozenProgress = frozenProgress
            self.scheduledLines = scheduledLines
            self.karaokeStartDate = karaokeStartDate
            self.karaokeEndDate = karaokeEndDate
            self.frozenKaraokeProgress = frozenKaraokeProgress
            self.albumDominantRGB = albumDominantRGB
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
