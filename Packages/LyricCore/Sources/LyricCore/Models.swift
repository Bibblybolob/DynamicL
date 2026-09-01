import Foundation

public struct TrackSignature: Hashable, Codable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct LyricLine: Hashable, Codable, Sendable, Comparable {
    public var time: TimeInterval
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }

    public static func < (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.time < rhs.time
    }
}

public struct LyricsDocument: Hashable, Codable, Sendable {
    public var track: TrackSignature
    public var lines: [LyricLine]

    public init(track: TrackSignature, lines: [LyricLine]) {
        self.track = track
        self.lines = lines.sorted()
    }

    /// Index of the line active at the given playback time, or nil before the first line.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    public func line(at time: TimeInterval) -> LyricLine? {
        lineIndex(at: time).map { lines[$0] }
    }
}

public struct PlaybackStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case playing
        case paused
        case stopped
    }

    public var state: State
    public var position: TimeInterval
    public var rate: Double
    public var timestamp: Date

    public init(state: State, position: TimeInterval, rate: Double = 1.0, timestamp: Date = .now) {
        self.state = state
        self.position = position
        self.rate = rate
        self.timestamp = timestamp
    }

    /// Best estimate of playback position at an arbitrary moment.
    public func position(at date: Date = .now) -> TimeInterval {
        guard state == .playing else { return position }
        let elapsed = max(0, date.timeIntervalSince(timestamp))
        return position + elapsed * rate
    }
}

/// Version 2 of the shared playback contract.
///
/// The app, widgets, Live Activity, Watch, and sync server use the same small
/// set of identity, timing, lyric, artwork, and color fields. The older
/// `WidgetLyricSnapshot` remains available as the renderer-facing format for
/// one compatibility release.
public struct SharedPlaybackSnapshotV2: Codable, Hashable, Sendable {
    public struct LyricInterval: Codable, Hashable, Sendable {
        public var startEpoch: TimeInterval
        public var endEpoch: TimeInterval?
        public var text: String

        public init(startEpoch: TimeInterval, endEpoch: TimeInterval? = nil, text: String) {
            self.startEpoch = startEpoch
            self.endEpoch = endEpoch
            self.text = text
        }
    }

    public var schemaVersion: Int
    public var trackID: String?
    public var trackTitle: String
    public var artistName: String
    public var albumImageURL: String?
    public var artworkKey: String?
    public var dominantRGB: [Double]?
    public var isPlaying: Bool
    public var trackDurationSeconds: TimeInterval?
    public var playbackEndEpoch: TimeInterval?
    public var playbackAnchorEpoch: TimeInterval?
    public var generatedAtEpoch: TimeInterval
    public var revision: Int64
    public var lyricOffsetSeconds: TimeInterval
    public var currentLine: String
    public var nextLine: String?
    public var lyricIntervals: [LyricInterval]

    public init(
        trackID: String? = nil,
        trackTitle: String,
        artistName: String,
        albumImageURL: String? = nil,
        artworkKey: String? = nil,
        dominantRGB: [Double]? = nil,
        isPlaying: Bool,
        trackDurationSeconds: TimeInterval? = nil,
        playbackEndEpoch: TimeInterval? = nil,
        playbackAnchorEpoch: TimeInterval? = nil,
        generatedAtEpoch: TimeInterval = Date.now.timeIntervalSince1970,
        revision: Int64 = 0,
        lyricOffsetSeconds: TimeInterval = 0,
        currentLine: String,
        nextLine: String? = nil,
        lyricIntervals: [LyricInterval] = []
    ) {
        self.schemaVersion = 2
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumImageURL = albumImageURL
        self.artworkKey = artworkKey
        self.dominantRGB = dominantRGB
        self.isPlaying = isPlaying
        self.trackDurationSeconds = trackDurationSeconds
        self.playbackEndEpoch = playbackEndEpoch
        self.playbackAnchorEpoch = playbackAnchorEpoch
        self.generatedAtEpoch = generatedAtEpoch
        self.revision = revision
        self.lyricOffsetSeconds = lyricOffsetSeconds
        self.currentLine = currentLine
        self.nextLine = nextLine
        self.lyricIntervals = lyricIntervals
    }
}
