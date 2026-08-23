import XCTest
@testable import LyricCore

final class LRCLIBParsingTests: XCTestCase {
    func testDecodesLRCLibResultJSON() throws {
        let json = """
        {
          "id": 123,
          "track_name": "The Chain",
          "artist_name": "Fleetwood Mac",
          "album_name": "Rumours",
          "duration": 271,
          "instrumental": false,
          "plain_lyrics": "line one\\nline two",
          "synced_lyrics": "[00:10.00]Listen to the wind blow\\n[00:13.50]Watch the sun rise"
        }
        """
        let result = try JSONDecoder().decode(LRCLibResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.trackName, "The Chain")
        XCTAssertEqual(result.syncedLyrics?.contains("[00:10.00]"), true)
        XCTAssertFalse(result.instrumental)
    }

    func testDocumentFromSyncedResult() throws {
        let result = LRCLibResult(
            id: 1,
            trackName: "T",
            artistName: "A",
            albumName: nil,
            duration: 30,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "[00:05.00]hello\n[00:10.00]world"
        )
        let doc = makeDocument(result: result, track: TrackSignature(title: "T", artist: "A"))
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.lines.count, 2)
        XCTAssertEqual(doc?.lines[0].time ?? -1, 5.0, accuracy: 0.001)
    }

    func testDocumentFromPlainResultSpacesLinesEvenly() throws {
        let result = LRCLibResult(
            id: 2,
            trackName: "T",
            artistName: "A",
            albumName: nil,
            duration: 30,
            instrumental: false,
            plainLyrics: "one\ntwo\nthree",
            syncedLyrics: nil
        )
        let doc = makeDocument(result: result, track: TrackSignature(title: "T", artist: "A"))
        XCTAssertEqual(doc?.lines.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(doc?.lines.map(\.time), [0.0, 3.0, 6.0])
    }

    func testInstrumentalResultYieldsNoDocument() throws {
        let result = LRCLibResult(
            id: 3,
            trackName: "T",
            artistName: "A",
            albumName: nil,
            duration: 30,
            instrumental: true,
            plainLyrics: nil,
            syncedLyrics: nil
        )
        let doc = makeDocument(result: result, track: TrackSignature(title: "T", artist: "A"))
        XCTAssertNil(doc)
    }

    private func makeDocument(result: LRCLibResult, track: TrackSignature) -> LyricsDocument? {
        if let lrc = result.syncedLyrics, !lrc.isEmpty,
           let doc = try? LRCParser.makeDocument(lrc: lrc, track: track), !doc.lines.isEmpty {
            return doc
        }
        if let plain = result.plainLyrics, !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: true)
                .enumerated()
                .map { index, text in LyricLine(time: TimeInterval(index) * 3.0, text: String(text)) }
            return lines.isEmpty ? nil : LyricsDocument(track: track, lines: lines)
        }
        return nil
    }
}
