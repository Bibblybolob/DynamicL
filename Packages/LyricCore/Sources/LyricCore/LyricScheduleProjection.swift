import Foundation

/// Projects one trusted playback sample onto an absolute, bounded lyric schedule.
/// This is the same position/offset calculation as SyncEngine, sampled once so
/// a line boundary cannot fall between computing the text and its future dates.
/// Consumers still need a system-supported opportunity to render those dates.
public struct LyricScheduleProjection: Sendable {
    public let position: TimeInterval
    public let currentIndex: Int?
    public let currentLine: String
    public let nextLine: String?
    public let currentStart: Date?
    public let currentEnd: Date?
    public let frozenKaraokeProgress: Double?
    public let futureLines: [WidgetLyricSnapshot.ScheduledLine]

    public init(document: LyricsDocument, status: PlaybackStatus,
                offset: TimeInterval, at date: Date,
                horizon: TimeInterval = 120, maxLines: Int = 64) {
        position = max(0, status.position(at: date))
        currentIndex = document.lineIndex(at: position - offset)
        currentLine = currentIndex.map { document.lines[$0].text } ?? "♪"
        let nextIndex = (currentIndex ?? -1) + 1
        nextLine = nextIndex < document.lines.count ? document.lines[nextIndex].text : nil
        if let index = currentIndex {
            let start = document.lines[index].time + offset
            let end = nextIndex < document.lines.count
                ? document.lines[nextIndex].time + offset
                : document.track.duration ?? start + 4
            if status.state == .playing {
                let rate = max(status.rate, 0.001)
                currentStart = date.addingTimeInterval((start - position) / rate)
                currentEnd = date.addingTimeInterval((end - position) / rate)
                frozenKaraokeProgress = nil
            } else {
                currentStart = nil
                currentEnd = nil
                frozenKaraokeProgress = min(max((position - start) / max(0.001, end - start), 0), 1)
            }
        } else {
            currentStart = nil
            currentEnd = nil
            frozenKaraokeProgress = nil
        }
        futureLines = status.state == .playing ? LyricBatchBuilder.make(
            document: document, position: position, offset: offset, now: date,
            rate: status.rate, horizon: horizon, maxLines: maxLines
        ).lines.map {
            .init(date: Date(timeIntervalSince1970: $0.startEpoch), text: $0.text,
                  endDate: Date(timeIntervalSince1970: $0.endEpoch))
        } : []
    }

    /// Include the active interval in persisted widget timelines so its end is
    /// known even when there are no future lines (or a bounded batch runs out).
    public var widgetLines: [WidgetLyricSnapshot.ScheduledLine] {
        guard let currentStart, let currentEnd else { return futureLines }
        return [.init(date: currentStart, text: currentLine, endDate: currentEnd)] + futureLines
    }
}
