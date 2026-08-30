import XCTest
@testable import LyricCore

final class LyricBatchTests: XCTestCase {
    func testBuildsFiveFutureLinesWithUnixBoundaries() {
        let document = LyricsDocument(
            track: TrackSignature(title: "Song", artist: "Artist", duration: 120),
            lines: [
                LyricLine(time: 0, text: "zero"),
                LyricLine(time: 10, text: "ten"),
                LyricLine(time: 20, text: "twenty"),
                LyricLine(time: 30, text: "thirty"),
                LyricLine(time: 40, text: "forty"),
                LyricLine(time: 50, text: "fifty"),
            ]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let batch = LyricBatchBuilder.make(
            document: document,
            position: 5,
            offset: 1,
            now: now,
            rate: 1,
            horizon: 60,
            maxLines: 5,
            trackID: "track-1"
        )

        XCTAssertEqual(batch.trackID, "track-1")
        XCTAssertEqual(batch.lines.map(\.text), ["ten", "twenty", "thirty", "forty", "fifty"])
        XCTAssertEqual(batch.lines[0].startEpoch, 1_700_000_006, accuracy: 0.001)
        XCTAssertEqual(batch.lines[0].endEpoch, 1_700_000_016, accuracy: 0.001)
        XCTAssertEqual(batch.generatedAtEpoch, 1_700_000_000, accuracy: 0.001)
    }

    func testBatchStopsAtOneMinuteAndFinalLineUsesTrackDuration() {
        let document = LyricsDocument(
            track: TrackSignature(title: "Song", artist: "Artist", duration: 90),
            lines: [
                LyricLine(time: 0, text: "zero"),
                LyricLine(time: 20, text: "twenty"),
                LyricLine(time: 78, text: "final"),
            ]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let batch = LyricBatchBuilder.make(
            document: document,
            position: 19,
            now: now,
            horizon: 60,
            maxLines: 5
        )

        XCTAssertEqual(batch.lines.map(\.text), ["twenty", "final"])
        XCTAssertEqual(batch.lines[1].endEpoch, 1_700_000_071, accuracy: 0.001)
        XCTAssertLessThanOrEqual(batch.lines.count, 5)
    }

    func testDefaultBatchCarriesMoreThanFiveLinesAcrossTheLookaheadWindow() {
        let document = LyricsDocument(
            track: TrackSignature(title: "Song", artist: "Artist", duration: 120),
            lines: (0..<40).map { index in
                LyricLine(time: TimeInterval(index * 2), text: "Line \(index)")
            }
        )

        let batch = LyricBatchBuilder.make(
            document: document,
            position: 0,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            trackID: "track-1"
        )

        XCTAssertEqual(batch.lines.count, 32)
        XCTAssertEqual(batch.lines.first?.text, "Line 1")
        XCTAssertEqual(batch.lines.last?.text, "Line 32")
        XCTAssertEqual(batch.lines.first?.startEpoch ?? -1, 1_700_000_002, accuracy: 0.001)
    }

    func testBatchDoesNotScheduleLyricsAfterPlaybackEnds() {
        let document = LyricsDocument(
            track: TrackSignature(title: "Song", artist: "Artist", duration: 30),
            lines: [
                LyricLine(time: 20, text: "last valid"),
                LyricLine(time: 29, text: "delayed past end"),
            ]
        )

        let batch = LyricBatchBuilder.make(
            document: document,
            position: 10,
            offset: 2,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            horizon: 60,
            maxLines: 5
        )

        XCTAssertEqual(batch.lines.map(\.text), ["last valid"])
        XCTAssertEqual(batch.lines[0].endEpoch, 1_700_000_020, accuracy: 0.001)
    }
}
