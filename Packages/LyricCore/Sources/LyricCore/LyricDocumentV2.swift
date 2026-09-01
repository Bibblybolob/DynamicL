import CryptoKit
import Foundation

public enum LyricDocumentSource: String, Codable, Hashable, Sendable {
    case lrclib
    case qqMusic
    case kugou
    case netease
    case imported
    case unknown
}

public struct LyricTrackIdentity: Codable, Hashable, Sendable, Equatable {
    public let spotifyTrackID: String
    public let title: String
    public let artist: String
    public let album: String?
    public let durationMs: Int?

    public init(
        spotifyTrackID: String,
        title: String,
        artist: String,
        album: String? = nil,
        durationMs: Int? = nil
    ) {
        self.spotifyTrackID = spotifyTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
    }
}

public struct LyricToken: Codable, Hashable, Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
    }
}

public struct LyricLineV2: Codable, Hashable, Sendable, Equatable {
    public let id: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval?
    public let originalText: String
    public let translatedText: String?
    public let tokens: [LyricToken]

    public init(
        id: String,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        originalText: String,
        translatedText: String? = nil,
        tokens: [LyricToken] = []
    ) {
        let start = max(0, startTime.isFinite ? startTime : 0)
        let normalizedEnd = endTime.flatMap { $0.isFinite ? max(start, $0) : nil }
        self.id = id
        self.startTime = start
        self.endTime = normalizedEnd
        self.originalText = originalText
        self.translatedText = translatedText
        self.tokens = tokens.sorted { $0.startTime < $1.startTime }
    }
}

/// Versioned lyric data shared by the app and the background service.
/// Translation timing belongs to the containing line. Only original text can
/// use word-level karaoke timing.
public struct LyricDocumentV2: Codable, Hashable, Sendable, Equatable {
    public let track: LyricTrackIdentity
    public let source: LyricDocumentSource
    public let sourceLanguage: String?
    public let targetLanguage: String?
    public let contentHash: String
    public let lines: [LyricLineV2]

    public init(
        track: LyricTrackIdentity,
        source: LyricDocumentSource,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        contentHash: String? = nil,
        lines: [LyricLineV2]
    ) {
        self.track = track
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.lines = lines.sorted { $0.startTime < $1.startTime }
        self.contentHash = contentHash ?? Self.makeContentHash(
            track: track,
            source: source,
            lines: self.lines
        )
    }

    public var hasWordTiming: Bool { lines.contains { !$0.tokens.isEmpty } }

    public static func makeContentHash(
        track: LyricTrackIdentity,
        source: LyricDocumentSource,
        lines: [LyricLineV2]
    ) -> String {
        let material = [
            track.spotifyTrackID,
            track.title,
            track.artist,
            source.rawValue,
            lines.map { line in
                [String(line.startTime), line.originalText, line.translatedText ?? ""]
                    .joined(separator: "|")
            }.joined(separator: "\n")
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
