import XCTest
@testable import LyricCore

final class LRCTests: XCTestCase {
    func testParsesBasicLRC() throws {
        let lrc = """
        [ti:Test Song]
        [ar:Test Artist]
        [00:12.50]First line
        [00:15.88]Second line
        [01:02.001]Third line
        """
        let result = try LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines[0].time, 12.5, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].text, "First line")
        XCTAssertEqual(result.lines[1].time, 15.88, accuracy: 0.001)
        XCTAssertEqual(result.lines[2].time, 62.001, accuracy: 0.0001)
    }

    func testMultipleTimestampsPerLine() throws {
        let lrc = "[00:10.00][00:20.00]Chorus"
        let result = try LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.map(\.time), [10.0, 20.0])
        XCTAssertTrue(result.lines.allSatisfy { $0.text == "Chorus" })
    }

    func testNegativeFractionalTimestamp() throws {
        let lrc = "[00:05.5]Half second"
        let result = try LRCParser.parse(lrc)
        XCTAssertEqual(result.lines[0].time, 5.5, accuracy: 0.0001)
    }

    func testOffsetTagShiftsEarlier() throws {
        let lrc = """
        [offset:2000]
        [00:10.00]Line
        """
        let doc = try LRCParser.makeDocument(lrc: lrc, track: TrackSignature(title: "T", artist: "A"))
        XCTAssertEqual(doc.lines[0].time, 8.0, accuracy: 0.0001)
    }

    func testSkipsMetadataAndEmptyLines() throws {
        let lrc = """
        [by:Someone]
        [00:01.00]

        [00:02.00]Real line
        """
        let result = try LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.map(\.text), ["Real line"])
    }

    func testThrowsWhenNoTimestampedLines() {
        XCTAssertThrowsError(try LRCParser.parse("just some words\nno timestamps here"))
    }

    func testLineIndexLookup() {
        let doc = LyricsDocument(
            track: TrackSignature(title: "T", artist: "A"),
            lines: [
                LyricLine(time: 0, text: "a"),
                LyricLine(time: 10, text: "b"),
                LyricLine(time: 20, text: "c"),
            ]
        )
        XCTAssertNil(doc.lineIndex(at: -1))
        XCTAssertEqual(doc.lineIndex(at: 0), 0)
        XCTAssertEqual(doc.lineIndex(at: 9.999), 0)
        XCTAssertEqual(doc.lineIndex(at: 10), 1)
        XCTAssertEqual(doc.lineIndex(at: 100), 2)
        XCTAssertEqual(doc.line(at: 15)?.text, "b")
    }
}
