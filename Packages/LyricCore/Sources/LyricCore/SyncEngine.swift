import Foundation

public final class SyncEngine {
    public private(set) var document: LyricsDocument?
    public private(set) var status: PlaybackStatus?

    /// Positive values delay lyrics (lines appear later); negative values show them earlier.
    public var userOffset: TimeInterval

    public init(userOffset: TimeInterval = 0) {
        self.userOffset = userOffset
    }

    public func update(document: LyricsDocument?) {
        self.document = document
    }

    public func update(status: PlaybackStatus?) {
        self.status = status
    }

    public func currentPosition(at date: Date = .now) -> TimeInterval? {
        guard let status else { return nil }
        return max(0, status.position(at: date))
    }

    public func currentIndex(at date: Date = .now) -> Int? {
        guard let position = currentPosition(at: date), let document else { return nil }
        return document.lineIndex(at: position - userOffset)
    }

    public func currentLine(at date: Date = .now) -> LyricLine? {
        guard let index = currentIndex(at: date), let document else { return nil }
        return document.lines[index]
    }
}
