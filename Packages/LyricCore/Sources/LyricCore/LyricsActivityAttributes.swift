#if os(iOS)
import ActivityKit

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var currentLine: String
        public var nextLine: String?
        public var isPlaying: Bool

        public init(currentLine: String, nextLine: String? = nil, isPlaying: Bool) {
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
        }
    }

    public var trackTitle: String
    public var artistName: String

    public init(trackTitle: String, artistName: String) {
        self.trackTitle = trackTitle
        self.artistName = artistName
    }
}
#endif
