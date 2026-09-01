import XCTest
@testable import LyricCore

final class LyricDocumentV2Tests: XCTestCase {
    func testDocumentSortsLinesAndComputesStableHash() {
        let track = LyricTrackIdentity(
            spotifyTrackID: "track-1",
            title: "Song",
            artist: "Artist"
        )
        let lines = [
            LyricLineV2(id: "b", startTime: 4, originalText: "Second"),
            LyricLineV2(id: "a", startTime: 1, originalText: "First")
        ]
        let first = LyricDocumentV2(track: track, source: .imported, lines: lines)
        let second = LyricDocumentV2(track: track, source: .imported, lines: lines.reversed())
        XCTAssertEqual(first.lines.map(\.id), ["a", "b"])
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertFalse(first.contentHash.isEmpty)
    }

    func testTokensAreSortedAndTranslationDoesNotCreateTokens() {
        let line = LyricLineV2(
            id: "line",
            startTime: 2,
            originalText: "hello",
            translatedText: "hola",
            tokens: [
                LyricToken(text: "lo", startTime: 3, endTime: 4),
                LyricToken(text: "hel", startTime: 2, endTime: 3)
            ]
        )
        XCTAssertEqual(line.tokens.map(\.text), ["hel", "lo"])
        XCTAssertEqual(line.translatedText, "hola")
    }
}
