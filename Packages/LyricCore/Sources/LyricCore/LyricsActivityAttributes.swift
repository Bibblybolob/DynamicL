#if os(iOS)
import ActivityKit

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var trackTitle: String
        public var artistName: String
        public var currentLine: String
        public var nextLine: String?
        public var isPlaying: Bool

        public init(trackTitle: String, artistName: String, currentLine: String, nextLine: String? = nil, isPlaying: Bool) {
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
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
