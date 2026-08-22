import Foundation

public enum LRCParserError: Error, Equatable {
    case noTimestampedLines
}

public struct LRCParseResult: Sendable, Equatable {
    public var lines: [LyricLine]
    public var offset: TimeInterval

    public init(lines: [LyricLine], offset: TimeInterval) {
        self.lines = lines
        self.offset = offset
    }
}

public enum LRCParser {
    /// Parses an LRC document into timestamped lines.
    ///
    /// Handles multiple timestamps per line, 2- or 3-digit fractional parts,
    /// and the global `[offset:+/-ms]` tag (positive shifts lyrics earlier).
    /// Empty lyric lines are dropped.
    public static func parse(_ lrc: String) throws -> LRCParseResult {
        let timestamp = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/
        var offset: TimeInterval = 0
        var parsed: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Substring(rawLine)

            let lowered = line.lowercased()
            if lowered.hasPrefix("[offset:") {
                if let start = lowered.firstIndex(of: ":"),
                   let end = lowered[start...].firstIndex(of: "]") {
                    let value = lowered[lowered.index(after: start)..<end]
                        .trimmingCharacters(in: .whitespaces)
                    offset += (Double(value) ?? 0) / 1000.0
                }
                continue
            }

            var rest = line
            var times: [TimeInterval] = []
            while let match = rest.firstMatch(of: timestamp), match.range.lowerBound == rest.startIndex {
                times.append(timestampValue(match))
                rest = rest[match.range.upperBound...]
            }

            guard !times.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for time in times {
                parsed.append((time, text))
            }
        }

        guard !parsed.isEmpty else { throw LRCParserError.noTimestampedLines }

        let lines = parsed
            .map { LyricLine(time: $0.time, text: $0.text) }
            .sorted()
        return LRCParseResult(lines: lines, offset: offset)
    }

    /// Builds a `LyricsDocument` with the LRC `[offset]` tag applied.
    ///
    /// Per-track user offsets are handled separately by `SyncEngine`.
    public static func makeDocument(lrc: String, track: TrackSignature) throws -> LyricsDocument {
        let result = try parse(lrc)
        let lines = result.lines.map { LyricLine(time: max(0, $0.time - result.offset), text: $0.text) }
        return LyricsDocument(track: track, lines: lines)
    }

    private static func timestampValue(_ match: Regex<(Substring, Substring, Substring, Substring?)>.Match) -> TimeInterval {
        let minutes = Double(match.1) ?? 0
        let seconds = Double(match.2) ?? 0
        var fraction = 0.0
        if let frac = match.3 {
            fraction = (Double(frac) ?? 0) / pow(10, Double(frac.count))
        }
        return minutes * 60 + seconds + fraction
    }
}
