import Foundation

/// Presentation-only context, resolved at the existing timeline boundaries.
public struct WidgetPresentation: Equatable, Sendable {
    public var current: String
    public var previous: String?
    public var next: String?
    public var title: String
    public var artist: String
    public var albumColor: RGB?
    public var artworkData: Data?
    public var album: String?
    public var isPlaying = false
    public var progressInterval: ClosedRange<Date>?
    public var frozenProgress: Double?
    public var elapsedSeconds: Double?
    public var durationSeconds: Double?


    public init(current: String, previous: String? = nil, next: String? = nil,
                title: String = "", artist: String = "", albumColor: RGB? = nil) {
        self.current = current
        self.previous = previous
        self.next = next
        self.title = title
        self.artist = artist
        self.albumColor = albumColor
    }

    public init(snapshot: WidgetLyricSnapshot, at date: Date) {
        self.init(current: snapshot.resolvedCurrentLine(at: date),
                  previous: snapshot.previousLine, next: snapshot.nextLine,
                  title: snapshot.trackTitle, artist: snapshot.artistName)
        if let rgb = snapshot.albumDominantRGB, rgb.count == 3, rgb.allSatisfy({ $0.isFinite }) {
            albumColor = RGB(r: rgb[0], g: rgb[1], b: rgb[2])
        }
        album = snapshot.albumName
        isPlaying = snapshot.isPlaying
        if let duration = snapshot.trackDuration, duration.isFinite, duration > 0 {
            durationSeconds = duration
            if snapshot.isPlaying, let anchor = snapshot.playbackAnchorEpoch, let end = snapshot.playbackEndEpoch,
               anchor.isFinite, end.isFinite, end > anchor {
                progressInterval = Date(timeIntervalSince1970: anchor)...Date(timeIntervalSince1970: end)
                elapsedSeconds = min(duration, max(0, (date.timeIntervalSince1970 - anchor) / (end - anchor) * duration))
            } else if let position = snapshot.frozenPositionSeconds, position.isFinite {
                elapsedSeconds = min(duration, max(0, position))
                frozenProgress = elapsedSeconds.map { $0 / duration }
            }
        }
        guard snapshot.isPlaying else { return }
        if let end = snapshot.playbackEndEpoch, date.timeIntervalSince1970 >= end {
            previous = nil
            next = nil
            return
        }
        let lines = snapshot.scheduledLines
        if let index = lines.lastIndex(where: { $0.date <= date }) {
            previous = index > 0 ? lines[index - 1].text : snapshot.previousLine
            next = index + 1 < lines.count ? lines[index + 1].text : nil
            if let end = lines[index].endDate, date >= end { previous = nil }
        } else {
            next = lines.first?.text ?? snapshot.nextLine
        }
    }

    public static let preview = WidgetPresentation(
        current: "Let the music\nfind you here",
        previous: "A little closer to the light",
        next: "And carry us into the night",
        title: "Into the Night", artist: "OpenLyrics",
        albumColor: RGB(r: 0.35, g: 0.25, b: 0.65)
    )
}
