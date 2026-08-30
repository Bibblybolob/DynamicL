import Foundation

/// One future lyric boundary in the shared playback clock.
///
/// The epoch fields are deliberately numeric. This keeps the phone, WidgetKit,
/// Live Activity, Watch, and server payloads on the same Unix time base.
public struct LyricBatchLine: Codable, Hashable, Sendable {
    public var startEpoch: TimeInterval
    public var endEpoch: TimeInterval
    public var text: String

    public init(startEpoch: TimeInterval, endEpoch: TimeInterval, text: String) {
        self.startEpoch = startEpoch
        self.endEpoch = endEpoch
        self.text = text
    }
}

/// A look-ahead window. It is sent as one batch so renderers can advance
/// between lyric boundaries without one ActivityKit update for every line.
public struct LyricBatch: Codable, Hashable, Sendable {
    public var generatedAtEpoch: TimeInterval
    public var trackID: String?
    public var lines: [LyricBatchLine]

    public init(generatedAtEpoch: TimeInterval,
                trackID: String? = nil,
                lines: [LyricBatchLine]) {
        self.generatedAtEpoch = generatedAtEpoch
        self.trackID = trackID
        self.lines = lines
    }

    public var horizonEpoch: TimeInterval? { lines.last?.endEpoch }
}

public enum LyricBatchBuilder {
    /// Builds a bounded look-ahead batch for a playback position.
    ///
    /// `position` is the Spotify playback position. A positive offset delays
    /// the lyric, therefore a line starts at `line.time + offset` on that
    /// clock. The final line ends at the track duration when available.
    public static func make(document: LyricsDocument,
                            position: TimeInterval,
                            offset: TimeInterval = 0,
                            now: Date = .now,
                            rate: Double = 1,
                            horizon: TimeInterval = 75,
                            maxLines: Int = 32,
                            trackID: String? = nil) -> LyricBatch {
        guard !document.lines.isEmpty, maxLines > 0, horizon > 0 else {
            return LyricBatch(generatedAtEpoch: now.timeIntervalSince1970,
                              trackID: trackID,
                              lines: [])
        }

        let safeRate = rate.isFinite && rate > 0 ? rate : 1
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeOffset = offset.isFinite ? offset : 0
        let trackDuration = document.track.duration.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let activeIndex = document.lineIndex(at: safePosition - safeOffset)
        let firstIndex = max(0, (activeIndex ?? -1) + 1)
        let endOfWindow = now.addingTimeInterval(horizon)

        var result: [LyricBatchLine] = []
        result.reserveCapacity(min(maxLines, document.lines.count))

        for index in firstIndex..<document.lines.count {
            guard result.count < maxLines else { break }
            let line = document.lines[index]
            let playbackStart = line.time + safeOffset
            // A positive user offset can move the final LRC boundary past the
            // actual track end. Do not schedule a lyric after playback ends,
            // or a widget timeline can revive stale text after its idle entry.
            if let trackDuration, playbackStart >= trackDuration { break }
            let delta = (playbackStart - safePosition) / safeRate
            guard delta > 0.05 else { continue }

            let start = now.addingTimeInterval(delta)
            guard start <= endOfWindow else { break }

            let nextPlaybackStart: TimeInterval
            if index + 1 < document.lines.count {
                nextPlaybackStart = document.lines[index + 1].time + safeOffset
            } else if let duration = trackDuration, duration > playbackStart {
                nextPlaybackStart = duration
            } else {
                nextPlaybackStart = playbackStart + 4
            }

            let boundedNextStart = trackDuration.map {
                min(nextPlaybackStart, $0)
            } ?? nextPlaybackStart
            let minimumVisibleDuration = min(
                0.25,
                max(0.01, boundedNextStart - playbackStart)
            )
            let endDelta = max(
                delta + minimumVisibleDuration / safeRate,
                (boundedNextStart - safePosition) / safeRate
            )
            let end = now.addingTimeInterval(endDelta)
            result.append(
                LyricBatchLine(startEpoch: start.timeIntervalSince1970,
                               endEpoch: end.timeIntervalSince1970,
                               text: line.text)
            )
        }

        return LyricBatch(generatedAtEpoch: now.timeIntervalSince1970,
                          trackID: trackID,
                          lines: result)
    }
}
