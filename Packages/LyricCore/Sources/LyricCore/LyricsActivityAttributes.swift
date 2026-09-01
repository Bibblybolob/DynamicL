#if os(iOS)
import ActivityKit
import Foundation

public enum ActivityUpdateSource: String, Codable, Hashable, Sendable {
    case phone
    case server
}

/// A future lyric boundary encoded with Unix time. Using a numeric epoch keeps
/// the Swift and JavaScript payloads identical and avoids Date's 2001 epoch.
public struct ActivityScheduledLine: Codable, Hashable, Sendable {
    public var dateEpoch: TimeInterval
    public var text: String
    public var endDateEpoch: TimeInterval?

    public init(dateEpoch: TimeInterval, text: String, endDateEpoch: TimeInterval? = nil) {
        self.dateEpoch = dateEpoch
        self.text = text
        self.endDateEpoch = endDateEpoch
    }

    public var date: Date { Date(timeIntervalSince1970: dateEpoch) }
}

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Version 2 uses Unix timestamps and records the update owner. Nil
        /// means a state produced by an older build.
        public var schemaVersion: Int?
        public var source: ActivityUpdateSource?
        public var revision: Int64?
        public var generatedAtEpoch: TimeInterval?
        public var trackID: String?
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
        /// Version 2 timing fields. The legacy Date fields above remain for
        /// one compatibility release and are decode fallbacks only.
        public var progressStartEpoch: TimeInterval?
        public var progressEndEpoch: TimeInterval?
        public var scheduledLinesV2: [ActivityScheduledLine]?
        public var karaokeStartEpoch: TimeInterval?
        public var karaokeEndEpoch: TimeInterval?
        /// A placeholder activity can ask the user to start the local lyric
        /// session. Optional keeps states from older builds decodable.
        public var requiresUserStart: Bool?

        public init(trackTitle: String, artistName: String, albumImageURL: String? = nil,
                    currentLine: String,
                    nextLine: String? = nil, isPlaying: Bool,
                    progressStart: Date? = nil, progressEnd: Date? = nil,
                    frozenProgress: Double? = nil,
                    scheduledLines: [WidgetLyricSnapshot.ScheduledLine]? = nil,
                    karaokeStartDate: Date? = nil,
                    karaokeEndDate: Date? = nil,
                    frozenKaraokeProgress: Double? = nil,
                    albumDominantRGB: [Double]? = nil,
                    schemaVersion: Int? = nil,
                    source: ActivityUpdateSource? = nil,
                    revision: Int64? = nil,
                    generatedAtEpoch: TimeInterval? = nil,
                    trackID: String? = nil,
                    progressStartEpoch: TimeInterval? = nil,
                    progressEndEpoch: TimeInterval? = nil,
                    scheduledLinesV2: [ActivityScheduledLine]? = nil,
                    karaokeStartEpoch: TimeInterval? = nil,
                    karaokeEndEpoch: TimeInterval? = nil,
                    requiresUserStart: Bool? = nil) {
            self.schemaVersion = schemaVersion
            self.source = source
            self.revision = revision
            self.generatedAtEpoch = generatedAtEpoch
            self.trackID = trackID
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
            self.progressStartEpoch = progressStartEpoch
            self.progressEndEpoch = progressEndEpoch
            self.scheduledLinesV2 = scheduledLinesV2
            self.karaokeStartEpoch = karaokeStartEpoch
            self.karaokeEndEpoch = karaokeEndEpoch
            self.requiresUserStart = requiresUserStart
        }

        public var resolvedProgressStart: Date? {
            progressStartEpoch.map(Date.init(timeIntervalSince1970:)) ?? progressStart
        }

        public var resolvedProgressEnd: Date? {
            progressEndEpoch.map(Date.init(timeIntervalSince1970:)) ?? progressEnd
        }

        public var resolvedKaraokeStart: Date? {
            karaokeStartEpoch.map(Date.init(timeIntervalSince1970:)) ?? karaokeStartDate
        }

        public var resolvedKaraokeEnd: Date? {
            karaokeEndEpoch.map(Date.init(timeIntervalSince1970:)) ?? karaokeEndDate
        }

        public var resolvedScheduledLines: [WidgetLyricSnapshot.ScheduledLine] {
            if let scheduledLinesV2 {
                return scheduledLinesV2.map {
                    .init(date: $0.date, text: $0.text, endDate: $0.endDateEpoch.map(Date.init(timeIntervalSince1970:)))
                }
            }
            return scheduledLines ?? []
        }

        public var encodedSize: Int {
            (try? JSONEncoder().encode(self).count) ?? .max
        }

        /// Keeps the dynamic state under ActivityKit's 4 KB limit. Future
        /// lines are removed before visible metadata, so an oversized lyric
        /// cannot make the whole update disappear.
        public func compacted(maxBytes: Int = 3_500) -> Self {
            var copy = self
            while copy.encodedSize > maxBytes {
                if var v2 = copy.scheduledLinesV2, !v2.isEmpty {
                    v2.removeLast()
                    copy.scheduledLinesV2 = v2.isEmpty ? nil : v2
                    continue
                }
                if var legacy = copy.scheduledLines, !legacy.isEmpty {
                    legacy.removeLast()
                    copy.scheduledLines = legacy.isEmpty ? nil : legacy
                    continue
                }
                break
            }

            if copy.encodedSize > maxBytes {
                // Keep the visible track and lyric text first. These optional
                // fields are useful, but they are not worth losing the whole
                // Activity update when an upstream response contains an
                // unusually long URL or legacy duplicate dates.
                copy.nextLine = nil
                copy.albumDominantRGB = nil
                copy.progressStart = nil
                copy.progressEnd = nil
                copy.karaokeStartDate = nil
                copy.karaokeEndDate = nil
                copy.progressStartEpoch = nil
                copy.progressEndEpoch = nil
                copy.karaokeStartEpoch = nil
                copy.karaokeEndEpoch = nil
            }
            if copy.encodedSize > maxBytes {
                copy.albumImageURL = nil
                copy.trackID = nil
                copy.currentLine = String(copy.currentLine.prefix(800))
                copy.trackTitle = String(copy.trackTitle.prefix(200))
                copy.artistName = String(copy.artistName.prefix(200))
            }
            if copy.encodedSize > maxBytes {
                // This is a final bounded fallback. Normal Spotify/LRCLIB
                // data never reaches it, but it guarantees that a malformed
                // field cannot create an ActivityKit-sized rejection loop.
                copy.currentLine = String(copy.currentLine.prefix(240))
                copy.trackTitle = String(copy.trackTitle.prefix(96))
                copy.artistName = String(copy.artistName.prefix(96))
            }
            return copy
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
